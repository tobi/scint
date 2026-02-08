# frozen_string_literal: true

require_relative "../errors"
require_relative "../fs"
require_relative "../platform"
require_relative "../progress"
require_relative "../worker_pool"
require_relative "../scheduler"
require_relative "../gemfile/dependency"
require_relative "../gemfile/parser"
require_relative "../lockfile/parser"
require_relative "../lockfile/writer"
require_relative "../source/base"
require_relative "../source/rubygems"
require_relative "../source/git"
require_relative "../source/path"
require_relative "../index/parser"
require_relative "../index/cache"
require_relative "../index/client"
require_relative "../downloader/fetcher"
require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../gem/extractor"
require_relative "../cache/layout"
require_relative "../cache/metadata_store"
require_relative "../installer/planner"
require_relative "../installer/linker"
require_relative "../installer/preparer"
require_relative "../installer/extension_builder"
require_relative "../vendor/pub_grub"
require_relative "../resolver/provider"
require_relative "../resolver/resolver"
require_relative "../credentials"
require "open3"
require "set"

module Scint
  module CLI
    class Install
      RUNTIME_LOCK = "scint.lock.marshal"

      def initialize(argv = [])
        @argv = argv
        @jobs = nil
        @path = nil
        @verbose = false
        @force = false
        @download_pool = nil
        @download_pool_lock = Thread::Mutex.new
        parse_options
      end

      def run
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        cache = Scint::Cache::Layout.new
        bundle_path = @path || ENV["BUNDLER_PATH"] || ".bundle"
        bundle_display = display_bundle_path(bundle_path)
        bundle_path = File.expand_path(bundle_path)
        worker_count = @jobs || [Platform.cpu_count * 2, 50].min
        compile_slots = compile_slots_for(worker_count)
        per_type_limits = install_task_limits(worker_count, compile_slots)
        $stdout.puts "#{GREEN}💎#{RESET} Scintellating Gemfile into #{BOLD}#{bundle_display}#{RESET} #{DIM}(scint #{VERSION}, ruby #{RUBY_VERSION})#{RESET}"
        $stdout.puts

        # 0. Build credential store from config files (~/.bundle/config, XDG scint/credentials)
        @credentials = Credentials.new

        # 1. Start the scheduler with 1 worker — scale up dynamically
        scheduler = Scheduler.new(max_workers: worker_count, fail_fast: true, per_type_limits: per_type_limits)
        scheduler.start

        begin
          # 2. Parse Gemfile
          gemfile = Scint::Gemfile::Parser.parse("Gemfile")

          # Register credentials from Gemfile sources and dependencies
          @credentials.register_sources(gemfile.sources)
          @credentials.register_dependencies(gemfile.dependencies)

          # Scale workers based on dependency count
          dep_count = gemfile.dependencies.size
          scheduler.scale_workers(dep_count)

          # 3. Enqueue index fetches for all sources immediately
          gemfile.sources.each do |source|
            scheduler.enqueue(:fetch_index, source[:uri] || source.to_s,
                              -> { fetch_index(source, cache) })
          end

          # 4. Parse lockfile if it exists
          lockfile = nil
          if File.exist?("Gemfile.lock")
            lockfile = Scint::Lockfile::Parser.parse("Gemfile.lock")
            @credentials.register_lockfile_sources(lockfile.sources)
          end

          # 5. Enqueue git clones for git sources
          git_sources = gemfile.sources.select { |s| s.is_a?(Source::Git) }
          git_sources.each do |source|
            scheduler.enqueue(:git_clone, source.uri,
                              -> { clone_git_source(source, cache) })
          end

          # 6. Wait for index fetches, then resolve
          scheduler.wait_for(:fetch_index)
          scheduler.wait_for(:git_clone)

          resolved = resolve(gemfile, lockfile, cache)
          resolved = dedupe_resolved_specs(adjust_meta_gems(resolved))
          force_purge_artifacts(resolved, bundle_path, cache) if @force

          # 7. Plan: diff resolved vs installed
          plan = Installer::Planner.plan(resolved, bundle_path, cache)
          total_gems = resolved.size
          updated_gems = plan.count { |e| e.action != :skip }
          cached_gems = total_gems - updated_gems
          to_install = plan.reject { |e| e.action == :skip }

          # Scale up for download/install phase based on actual work count
          scheduler.scale_workers(to_install.size)

          if to_install.empty?
            elapsed_ms = elapsed_ms_since(start_time)
            worker_count = scheduler.stats[:workers]
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
            return 0
          end

          # 8. Build a dependency-aware task graph:
          # download -> link_files -> build_ext -> binstub (where applicable).
          compiled_count = enqueue_install_dag(
            scheduler,
            plan,
            cache,
            bundle_path,
            scheduler.progress,
            compile_slots: compile_slots,
          )

          # 9. Wait for everything
          scheduler.wait_all
          compiled_gems = compiled_count.respond_to?(:call) ? compiled_count.call : compiled_count
          # Stop live progress before printing final summaries/errors so
          # cursor movement does not erase trailing output.
          scheduler.progress.stop if scheduler.respond_to?(:progress)

          errors = scheduler.errors.dup
          stats = scheduler.stats
          if errors.any?
            $stderr.puts "#{RED}Some gems failed to install:#{RESET}"
            errors.each do |err|
              error = err[:error]
              $stderr.puts "  #{BOLD}#{err[:name]}#{RESET}: #{error.message}"
              emit_network_error_details(error)
            end
          elsif stats[:failed] > 0
            $stderr.puts "#{YELLOW}Warning: #{stats[:failed]} jobs failed but no error details captured#{RESET}"
          end

          elapsed_ms = elapsed_ms_since(start_time)
          worker_count = stats[:workers]
          failed = errors.filter_map { |e| e[:name] }.uniq
          failed_count = failed.size
          failed_count = 1 if failed_count.zero? && stats[:failed] > 0
          installed_total = [total_gems - failed_count, 0].max
          has_failures = errors.any? || stats[:failed] > 0

          if has_failures
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{RED}Bundle failed!#{RESET} #{installed_total}/#{total_gems} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems, failed: failed_count)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
            1
          else
            # 10. Write lockfile + runtime config only for successful installs
            write_lockfile(resolved, gemfile, lockfile)
            write_runtime_config(resolved, bundle_path)
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
            0
          end
        ensure
          begin
            scheduler.shutdown
          ensure
            close_download_pool
          end
        end
      end

      private

      # --- Spec adjustment ---

      # Post-resolution pass: remove bundler (we replace it) and inject scint.
      # This ensures `require "bundler/setup"` loads our shim, and scint
      # appears in the gem list just like bundler does for stock bundler.
      def adjust_meta_gems(resolved)
        resolved = resolved.reject { |s| s.name == "bundler" || s.name == "scint" }

        scint_spec = ResolvedSpec.new(
          name: "scint",
          version: VERSION,
          platform: "ruby",
          dependencies: [],
          source: "scint (built-in)",
          has_extensions: false,
          remote_uri: nil,
          checksum: nil,
        )
        resolved.unshift(scint_spec)

        resolved
      end

      def dedupe_resolved_specs(resolved)
        seen = {}
        resolved.each do |spec|
          key = "#{spec.name}-#{spec.version}-#{spec.platform}"
          seen[key] ||= spec
        end
        seen.values
      end

      # Install scint into the bundle by copying our own lib tree.
      # No download needed — we know exactly where we are.
      def install_builtin_gem(entry, bundle_path)
        spec = entry.spec
        ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
        full_name = spec_full_name(spec)
        scint_root = File.expand_path("../../..", __FILE__)

        # Copy gem files into gems/scint-x.y.z/lib/
        gem_dest = File.join(ruby_dir, "gems", full_name)
        lib_dest = File.join(gem_dest, "lib")
        unless Dir.exist?(lib_dest)
          FS.mkdir_p(lib_dest)
          FS.clone_tree(scint_root, lib_dest)
        end

        # Write gemspec
        spec_dir = File.join(ruby_dir, "specifications")
        spec_path = File.join(spec_dir, "#{full_name}.gemspec")
        unless File.exist?(spec_path)
          FS.mkdir_p(spec_dir)
          content = <<~RUBY
            Gem::Specification.new do |s|
              s.name = #{spec.name.inspect}
              s.version = #{spec.version.to_s.inspect}
              s.summary = "Fast, parallel gem installer (bundler replacement)"
              s.require_paths = ["lib"]
            end
          RUBY
          FS.atomic_write(spec_path, content)
        end
      end

      # --- Phase implementations ---

      def fetch_index(source, cache)
        return unless source.respond_to?(:remotes)
        # Compact index fetch is handled by the index client;
        # we just trigger it here so the data is cached.
        source.remotes.each do |remote|
          cache.ensure_dir(cache.index_path(source))
        end
      end

      def clone_git_source(source, cache)
        return unless source.respond_to?(:uri)
        git_dir = cache.git_path(source.uri)
        if Dir.exist?(git_dir)
          fetch_git_repo(git_dir)
          return
        end

        clone_git_repo(source.uri, git_dir)
      end

      def resolve(gemfile, lockfile, cache)
        # If lockfile is up-to-date, use its specs directly
        if lockfile && lockfile_current?(gemfile, lockfile) && lockfile_git_source_mapping_valid?(lockfile, cache)
          return lockfile_to_resolved(lockfile)
        end

        # Collect all unique rubygems source URIs
        default_uri = gemfile.sources.first&.dig(:uri) || "https://rubygems.org"
        all_uris = Set.new([default_uri])
        gemfile.sources.each do |src|
          all_uris << src[:uri] if src[:type] == :rubygems && src[:uri]
        end

        # Also collect inline source: options from dependencies
        gemfile.dependencies.each do |dep|
          if dep.source_options[:source]
            all_uris << dep.source_options[:source]
          end
        end

        # Create one Index::Client per unique source URI
        clients = {}
        all_uris.each do |uri|
          clients[uri] = Index::Client.new(uri, credentials: @credentials)
        end
        default_client = clients[default_uri]

        # Build source_map: gem_name => source_uri for gems with explicit sources
        source_map = {}
        gemfile.dependencies.each do |dep|
          src = dep.source_options[:source]
          source_map[dep.name] = src if src
        end

        # Build path_gems: gem_name => { version:, dependencies:, source: }
        # for gems with path: or git: sources (skip compact index for these)
        path_gems = {}
        gemfile.dependencies.each do |dep|
          opts = dep.source_options
          next unless opts[:path] || opts[:git]

          version = "0"
          deps = []

          # Try to read version and deps from gemspec if it's a path gem
          if opts[:path]
            gemspec = find_gemspec(opts[:path], dep.name, glob: opts[:glob])
            if gemspec
              version = gemspec.version.to_s
              deps = gemspec.dependencies
                .select { |d| d.type == :runtime }
                .map do |d|
                  requirement_parts = d.requirement.requirements.map { |op, req_version| "#{op} #{req_version}" }
                  [d.name, requirement_parts]
                end
            end
          end

          # For git gems, try lockfile for version
          if opts[:git] && lockfile
            locked_spec = lockfile.specs.find { |s| s[:name] == dep.name }
            version = locked_spec[:version] if locked_spec
          end

          source_desc = opts[:path] || opts[:git] || "local"
          path_gems[dep.name] = { version: version, dependencies: deps, source: source_desc }
        end

        locked = {}
        if lockfile
          lockfile.specs.each { |s| locked[s[:name]] = s[:version] }
        end

        provider = Resolver::Provider.new(
          default_client,
          clients: clients,
          source_map: source_map,
          path_gems: path_gems,
          locked_specs: locked,
        )
        resolver = Resolver::Resolver.new(
          provider: provider,
          dependencies: gemfile.dependencies,
          locked_specs: locked,
        )
        resolver.resolve
      end

      def find_gemspec(path, gem_name, glob: nil)
        return nil unless Dir.exist?(path)

        glob_pattern = glob || Source::Path::DEFAULT_GLOB
        # Look for exact match first, then any gemspec
        candidates = [
          File.join(path, "#{gem_name}.gemspec"),
          *Dir.glob(File.join(path, glob_pattern)),
          *Dir.glob(File.join(path, "*.gemspec")),
        ].uniq

        candidates.each do |gs|
          next unless File.exist?(gs)
          begin
            spec = Gem::Specification.load(gs)
            return spec if spec
          rescue StandardError
            nil
          end
        end
        nil
      end

      def lockfile_current?(gemfile, lockfile)
        return false unless lockfile

        locked_names = Set.new(lockfile.specs.map { |s| s[:name] })
        gemfile.dependencies.all? do |dep|
          next true unless dependency_relevant_for_local_platform?(dep)

          locked_names.include?(dep.name)
        end
      end

      def dependency_relevant_for_local_platform?(dependency)
        platforms = Array(dependency.platforms).map(&:to_sym)
        return true if platforms.empty?

        platforms.any? { |platform| gemfile_platform_matches_local?(platform) }
      end

      def gemfile_platform_matches_local?(platform)
        case platform
        when :ruby
          true
        when :mri
          RUBY_ENGINE == "ruby"
        when :jruby
          RUBY_ENGINE == "jruby"
        when :truffleruby
          RUBY_ENGINE == "truffleruby"
        when :rbx
          RUBY_ENGINE == "rbx"
        when :windows, :mswin, :mswin64, :mingw, :x64_mingw, :x86_mingw, :x64_mingw_ucrt
          Platform.windows?
        when :linux
          Platform.linux?
        when :darwin, :macos
          Platform.macos?
        else
          platform_name = platform.to_s.tr("_", "-")
          spec_platform = Gem::Platform.new(platform_name)
          spec_platform === Platform.local_platform
        end
      rescue StandardError
        false
      end

      def lockfile_to_resolved(lockfile)
        local_plat = Platform.local_platform

        # Pick one best platform variant per gem+version from lockfile specs.
        by_gem = Hash.new { |h, k| h[k] = [] }
        lockfile.specs.each { |ls| by_gem[[ls[:name], ls[:version]]] << ls }

        resolved = by_gem.map do |(_name, _version), specs|
          best = pick_best_platform_spec(specs, local_plat)

          source = best[:source]
          source_value =
            if source.is_a?(Source::Rubygems)
              source.uri.to_s
            else
              source
            end

          ResolvedSpec.new(
            name: best[:name],
            version: best[:version],
            platform: best[:platform],
            dependencies: best[:dependencies],
            source: source_value,
            has_extensions: false,
            remote_uri: nil,
            checksum: best[:checksum],
          )
        end

        apply_locked_platform_preferences(resolved)
      end

      def lockfile_git_source_mapping_valid?(lockfile, cache)
        return true unless lockfile && cache

        git_specs = Array(lockfile.specs).select { |s| s[:source].is_a?(Source::Git) }
        return true if git_specs.empty?

        by_source = git_specs.group_by { |s| s[:source] }
        by_source.each do |source, specs|
          uri, revision = git_source_ref(source)
          bare_repo = cache.git_path(uri)
          return false unless Dir.exist?(bare_repo)

          resolved_revision = begin
            resolve_git_revision(bare_repo, revision)
          rescue InstallError
            nil
          end
          return false unless resolved_revision

          gemspec_names = gemspec_names_in_git_revision(bare_repo, resolved_revision)
          return false if gemspec_names.empty?

          specs.each do |spec|
            return false unless gemspec_names.include?(spec[:name].to_s)
          end
        end

        true
      end

      def gemspec_names_in_git_revision(bare_repo, revision)
        out, err, status = git_capture3(
          "--git-dir", bare_repo,
          "ls-tree",
          "-r",
          "--name-only",
          revision,
        )
        return Set.new unless status.success?

        names = Set.new
        out.each_line do |line|
          path = line.strip
          next unless path.end_with?(".gemspec")
          names << File.basename(path, ".gemspec")
        end
        names
      rescue StandardError
        Set.new
      end

      # Preference: exact platform match > compatible match > ruby > first.
      def pick_best_platform_spec(specs, local_plat)
        return specs.first if specs.size == 1

        best = nil
        best_score = -2

        specs.each do |ls|
          platform = ls[:platform] || "ruby"
          if platform == "ruby"
            score = 0
          else
            spec_plat = Gem::Platform.new(platform)
            if spec_plat === local_plat
              score = spec_plat.to_s == local_plat.to_s ? 2 : 1
            else
              score = -1
            end
          end

          if score > best_score
            best = ls
            best_score = score
          end
        end

        best
      end

      # Lockfiles can carry only the ruby variant for a gem version.
      # Re-check compact index for the same locked version and upgrade to the
      # best local platform variant when available.
      def apply_locked_platform_preferences(resolved_specs)
        preferred = preferred_platforms_for_locked_specs(resolved_specs)
        return resolved_specs if preferred.empty?

        resolved_specs.each do |spec|
          key = "#{spec.name}-#{spec.version}"
          platform = preferred[key]
          next if platform.nil? || platform.empty?

          spec.platform = platform
        end

        resolved_specs
      end

      def preferred_platforms_for_locked_specs(resolved_specs)
        out = {}
        by_source = resolved_specs
          .select { |spec| rubygems_source_uri?(spec.source) }
          .group_by { |spec| spec.source.to_s.chomp("/") }

        by_source.each do |source_uri, specs|
          begin
            client = Index::Client.new(source_uri, credentials: @credentials)
            provider = Resolver::Provider.new(client)
            provider.prefetch(specs.map(&:name).uniq)

            specs.each do |spec|
              preferred = provider.preferred_platform_for(spec.name, Gem::Version.new(spec.version.to_s))
              preferred = preferred.to_s
              next if preferred.empty? || preferred == spec.platform.to_s

              out["#{spec.name}-#{spec.version}"] = preferred
            end
          rescue StandardError
            next
          end
        end

        out
      end

      def rubygems_source_uri?(source)
        source.is_a?(String) && source.match?(%r{\Ahttps?://})
      end

      def download_gem(entry, cache)
        spec = entry.spec
        source = spec.source
        if git_source?(source)
          prepare_git_checkout(spec, cache, fetch: false)
          return
        end
        source_uri = source.to_s

        # Path gems are not downloaded from a remote
        return if source_uri.start_with?("/") || !source_uri.start_with?("http")

        full_name = spec_full_name(spec)
        gem_filename = "#{full_name}.gem"
        source_uri = source_uri.chomp("/")
        download_uri = "#{source_uri}/gems/#{gem_filename}"
        dest_path = cache.inbound_path(spec)

        FS.mkdir_p(File.dirname(dest_path))

        unless File.exist?(dest_path)
          downloader_pool.download(download_uri, dest_path)
        end
      end

      def downloader_pool
        @download_pool_lock.synchronize do
          @download_pool ||= Downloader::Pool.new(credentials: @credentials)
        end
      end

      def close_download_pool
        @download_pool_lock.synchronize do
          @download_pool&.close
          @download_pool = nil
        end
      end

      def extract_gem(entry, cache)
        spec = entry.spec
        source_uri = spec.source.to_s

        # Git gems are extracted from the cached checkout; path gems are
        # linked directly from local source.
        if git_source?(spec.source)
          materialize_git_spec(entry, cache)
          return
        end
        return if source_uri.start_with?("/") || !source_uri.start_with?("http")

        extracted = cache.extracted_path(spec)
        return if Dir.exist?(extracted)

        dest_path = cache.inbound_path(spec)
        raise InstallError, "Missing cached gem file for #{spec.name}: #{dest_path}" unless File.exist?(dest_path)

        FS.mkdir_p(extracted)
        pkg = GemPkg::Package.new
        result = pkg.extract(dest_path, extracted)
        cache_gemspec(spec, result[:gemspec], cache)
      end

      def git_source?(source)
        return true if source.is_a?(Source::Git)

        source_str = source.to_s
        source_str.end_with?(".git") || source_str.include?(".git/")
      end

      def prepare_git_source(entry, cache)
        # Legacy helper used by tests/callers that expect git download+extract
        # in a single step.
        spec = entry.spec
        checkout_dir, resolved_revision, _uri = prepare_git_checkout(spec, cache, fetch: true)
        materialize_git_spec(entry, cache, checkout_dir: checkout_dir, resolved_revision: resolved_revision)
      end

      def prepare_git_checkout(spec, cache, fetch: false)
        source = spec.source
        uri, revision = git_source_ref(source)

        bare_repo = cache.git_path(uri)

        # Serialize all git operations per bare repo — git uses index.lock
        # and can't handle concurrent checkouts from the same repo.
        git_mutex_for(bare_repo).synchronize do
          if Dir.exist?(bare_repo)
            fetch_git_repo(bare_repo) if fetch
          else
            clone_git_repo(uri, bare_repo)
            fetch_git_repo(bare_repo)
          end

          resolved_revision = resolve_git_revision(bare_repo, revision)
          incoming_checkout = cache.git_checkout_path(uri, resolved_revision)
          materialize_git_checkout(bare_repo, incoming_checkout, resolved_revision, spec, uri)
          [incoming_checkout, resolved_revision, uri]
        end
      end

      def materialize_git_spec(entry, cache, checkout_dir: nil, resolved_revision: nil)
        spec = entry.spec
        checkout_dir, resolved_revision, _uri = prepare_git_checkout(spec, cache, fetch: false) unless checkout_dir && resolved_revision
        gem_root = resolve_git_gem_subdir(checkout_dir, spec)
        extracted = cache.extracted_path(spec)
        marker = git_checkout_marker_path(extracted)
        if Dir.exist?(extracted) && File.exist?(marker) && File.read(marker).strip == resolved_revision
          return
        end

        tmp = "#{extracted}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        begin
          FileUtils.rm_rf(tmp)
          FS.clone_tree(gem_root, tmp)

          FileUtils.rm_rf(extracted)
          FS.atomic_move(tmp, extracted)
          FS.atomic_write(marker, "#{resolved_revision}\n")
        ensure
          FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
        end
      end

      def materialize_git_checkout(bare_repo, checkout_dir, resolved_revision, spec, uri)
        marker = git_checkout_marker_path(checkout_dir)
        if Dir.exist?(checkout_dir) && File.exist?(marker)
          return if File.read(marker).strip == resolved_revision
        end

        tmp = "#{checkout_dir}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        begin
          FileUtils.rm_rf(tmp)
          FileUtils.mkdir_p(tmp)

          _out, err, status = git_capture3(
            "--git-dir", bare_repo,
            "--work-tree", tmp,
            "checkout",
            "-f",
            resolved_revision,
            "--",
            ".",
          )
          unless status.success?
            raise InstallError, "Git checkout failed for #{spec.name} (#{uri}@#{resolved_revision}): #{err.to_s.strip}"
          end

          FileUtils.rm_rf(checkout_dir)
          FS.atomic_move(tmp, checkout_dir)
          FS.atomic_write(marker, "#{resolved_revision}\n")
        ensure
          FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
        end
      end

      def git_source_ref(source)
        if source.is_a?(Source::Git)
          revision = source.revision || source.ref || source.branch || source.tag || "HEAD"
          return [source.uri.to_s, revision.to_s]
        end

        [source.to_s, "HEAD"]
      end

      def git_mutex_for(repo_path)
        @git_mutexes_lock ||= Thread::Mutex.new
        @git_mutexes_lock.synchronize do
          @git_mutexes ||= {}
          @git_mutexes[repo_path] ||= Thread::Mutex.new
        end
      end

      def clone_git_repo(uri, bare_repo)
        FS.mkdir_p(File.dirname(bare_repo))
        _out, err, status = git_capture3("clone", "--bare", uri.to_s, bare_repo)
        unless status.success?
          raise InstallError, "Git clone failed for #{uri}: #{err.to_s.strip}"
        end
      end

      def fetch_git_repo(bare_repo)
        _out, err, status = git_capture3(
          "--git-dir", bare_repo,
          "fetch",
          "--prune",
          "origin",
          "+refs/heads/*:refs/heads/*",
          "+refs/tags/*:refs/tags/*",
        )
        unless status.success?
          raise InstallError, "Git fetch failed for #{bare_repo}: #{err.to_s.strip}"
        end
      end

      def resolve_git_revision(bare_repo, revision)
        out, err, status = git_capture3("--git-dir", bare_repo, "rev-parse", "#{revision}^{commit}")
        unless status.success?
          raise InstallError, "Unable to resolve git revision #{revision.inspect} in #{bare_repo}: #{err.to_s.strip}"
        end
        out.strip
      end

      def git_capture3(*args)
        Open3.capture3("git", "-c", "core.fsmonitor=false", *args)
      end

      def git_checkout_marker_path(dir)
        "#{dir}.scint_git_revision"
      end

      def compile_slots_for(worker_count)
        # Keep native builds serialized to avoid build-env races and reduce
        # memory/CPU spikes from concurrent extension compiles.
        _ = worker_count
        1
      end

      def install_task_limits(worker_count, compile_slots)
        # Leave headroom for compile and binstub lanes so link/download
        # throughput cannot fully starve them.
        io_cpu_limit = [worker_count - compile_slots - 1, 1].max
        # Keep download in-flight set bounded so fail-fast exits quickly on
        # auth/source errors instead of queueing a large burst.
        download_limit = [io_cpu_limit, 8].min
        {
          download: download_limit,
          extract: io_cpu_limit,
          link: io_cpu_limit,
          build_ext: compile_slots,
          binstub: 1,
        }
      end

      def display_bundle_path(path)
        return path if path.start_with?("/", "./", "../")

        "./#{path}"
      end

      # Enqueue dependency-aware install tasks so compile/binstub can run
      # concurrently with link/download once prerequisites are satisfied.
      def enqueue_install_dag(scheduler, plan, cache, bundle_path, progress = nil, compile_slots: 1)
        link_job_by_key = {}
        link_job_by_name = {}
        build_job_by_key = {}
        build_count = 0
        build_count_lock = Thread::Mutex.new

        plan.each do |entry|
          case entry.action
          when :skip
            next
          when :builtin
            link_id = scheduler.enqueue(:link, entry.spec.name,
                                        -> { install_builtin_gem(entry, bundle_path) })
          when :download
            key = spec_key(entry.spec)
            download_id = scheduler.enqueue(:download, entry.spec.name,
                                            -> { download_gem(entry, cache) })
            extract_id = scheduler.enqueue(:extract, entry.spec.name,
                                           -> { extract_gem(entry, cache) },
                                           depends_on: [download_id],
                                           follow_up: lambda { |_job|
                                             own_link = link_job_by_key[key]
                                             next unless own_link

                                             depends_on = [own_link]
                                             dep_links = dependency_link_job_ids(entry.spec, link_job_by_name)
                                             build_depends = (depends_on + dep_links).uniq

                                             extracted = extracted_path_for_entry(entry, cache)
                                             if Installer::ExtensionBuilder.needs_build?(entry.spec, extracted)
                                               build_id = scheduler.enqueue(:build_ext, entry.spec.name,
                                                                            -> { build_extensions(entry, cache, bundle_path, progress, compile_slots: compile_slots) },
                                                                            depends_on: build_depends)
                                               build_job_by_key[key] = build_id
                                               depends_on << build_id
                                               build_count_lock.synchronize { build_count += 1 }
                                             end

                                             scheduler.enqueue(:binstub, entry.spec.name,
                                                               -> { write_binstubs(entry, cache, bundle_path) },
                                                               depends_on: depends_on)
                                           })
            link_id = scheduler.enqueue(:link, entry.spec.name,
                                        -> { link_gem_files(entry, cache, bundle_path) },
                                        depends_on: [extract_id])
          when :link, :build_ext
            link_id = scheduler.enqueue(:link, entry.spec.name,
                                        -> { link_gem_files(entry, cache, bundle_path) })
          else
            next
          end

          key = spec_key(entry.spec)
          link_job_by_key[key] = link_id
          link_job_by_name[entry.spec.name] = link_id
        end

        plan.each do |entry|
          next unless entry.action == :build_ext

          key = spec_key(entry.spec)
          own_link = link_job_by_key[key]
          next unless own_link

          dep_links = dependency_link_job_ids(entry.spec, link_job_by_name)
          depends_on = ([own_link] + dep_links).uniq
          build_id = scheduler.enqueue(:build_ext, entry.spec.name,
                                       -> { build_extensions(entry, cache, bundle_path, progress, compile_slots: compile_slots) },
                                       depends_on: depends_on)
          build_job_by_key[key] = build_id
          build_count_lock.synchronize { build_count += 1 }
        end

        plan.each do |entry|
          next if entry.action == :skip || entry.action == :builtin || entry.action == :download

          key = spec_key(entry.spec)
          own_link = link_job_by_key[key]
          next unless own_link

          depends_on = [own_link]
          build_id = build_job_by_key[key]
          depends_on << build_id if build_id
          scheduler.enqueue(:binstub, entry.spec.name,
                            -> { write_binstubs(entry, cache, bundle_path) },
                            depends_on: depends_on)
        end

        -> { build_count_lock.synchronize { build_count } }
      end

      def spec_key(spec)
        "#{spec.name}-#{spec.version}-#{spec.platform}"
      end

      def dependency_link_job_ids(spec, link_job_by_name)
        names = Array(spec.dependencies).filter_map do |dep|
          if dep.is_a?(Hash)
            dep[:name] || dep["name"]
          elsif dep.respond_to?(:name)
            dep.name
          end
        end
        names.filter_map { |name| link_job_by_name[name] }.uniq
      end

      def enqueue_link_after_download(scheduler, entry, cache, bundle_path)
        scheduler.enqueue(:link, entry.spec.name,
                          -> { link_gem_files(entry, cache, bundle_path) })
      end

      def enqueue_builds(scheduler, entries, cache, bundle_path, compile_slots: 1)
        enqueued = 0
        entries.each do |entry|
          extracted = extracted_path_for_entry(entry, cache)
          next unless Installer::ExtensionBuilder.needs_build?(entry.spec, extracted)

          scheduler.enqueue(:build_ext, entry.spec.name,
                            -> { build_extensions(entry, cache, bundle_path, nil, compile_slots: compile_slots) })
          enqueued += 1
        end
        enqueued
      end

      def extracted_path_for_entry(entry, cache)
        source_str = entry.spec.source.to_s
        if source_str.start_with?("/") && Dir.exist?(source_str)
          source_str
        else
          base = entry.cached_path || cache.extracted_path(entry.spec)
          if git_source?(entry.spec.source) && Dir.exist?(base)
            resolve_git_gem_subdir(base, entry.spec)
          else
            base
          end
        end
      end

      # For git monorepo sources, map gem name to its gemspec subdirectory.
      def resolve_git_gem_subdir(repo_root, spec)
        name = spec.name
        return repo_root if File.exist?(File.join(repo_root, "#{name}.gemspec"))

        source = spec.source
        glob = source.respond_to?(:glob) ? source.glob : Source::Git::DEFAULT_GLOB
        Dir.glob(File.join(repo_root, glob)).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end
        # Compatibility fallback for monorepos whose gem layout does not match
        # the lockfile glob exactly.
        Dir.glob(File.join(repo_root, "**", "*.gemspec")).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end

        source_uri = source.respond_to?(:uri) ? source.uri : source.to_s
        raise InstallError,
              "Git source #{source_uri} does not contain #{name}.gemspec (glob: #{glob.inspect}); lockfile source mapping may be stale"
      end

      def link_gem_files(entry, cache, bundle_path)
        spec = entry.spec
        extracted = extracted_path_for_entry(entry, cache)

        gemspec = load_gemspec(extracted, spec, cache)

        prepared = PreparedGem.new(
          spec: spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )
        Installer::Linker.link_files(prepared, bundle_path)
        # If this gem has a cached native build, materialize it during link.
        # This lets reinstalling into a fresh .bundle skip build_ext entirely.
        Installer::ExtensionBuilder.link_cached_build(prepared, bundle_path, cache)
      end

      def build_extensions(entry, cache, bundle_path, progress = nil, compile_slots: 1)
        extracted = extracted_path_for_entry(entry, cache)
        gemspec = load_gemspec(extracted, entry.spec, cache)

        sync_build_env_dependencies(entry.spec, bundle_path, cache)

        prepared = PreparedGem.new(
          spec: entry.spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )

        Installer::ExtensionBuilder.build(
          prepared,
          bundle_path,
          cache,
          compile_slots: compile_slots,
          output_tail: ->(lines) { progress&.on_build_tail(entry.spec.name, lines) },
        )
      end

      def sync_build_env_dependencies(spec, bundle_path, cache)
        dep_names = Array(spec.dependencies).filter_map do |dep|
          if dep.is_a?(Hash)
            dep[:name] || dep["name"]
          elsif dep.respond_to?(:name)
            dep.name
          end
        end
        dep_names << "rake"
        dep_names.uniq!
        return if dep_names.empty?

        source_ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
        target_ruby_dir = cache.install_ruby_dir

        dep_names.each do |name|
          sync_named_gem_to_build_env(name, source_ruby_dir, target_ruby_dir)
        end
      end

      def sync_named_gem_to_build_env(name, source_ruby_dir, target_ruby_dir)
        pattern = File.join(source_ruby_dir, "specifications", "#{name}-*.gemspec")
        Dir.glob(pattern).each do |spec_path|
          full_name = File.basename(spec_path, ".gemspec")
          source_gem_dir = File.join(source_ruby_dir, "gems", full_name)
          next unless Dir.exist?(source_gem_dir)

          target_gem_dir = File.join(target_ruby_dir, "gems", full_name)
          FS.clone_tree(source_gem_dir, target_gem_dir) unless Dir.exist?(target_gem_dir)

          target_spec_dir = File.join(target_ruby_dir, "specifications")
          target_spec_path = File.join(target_spec_dir, "#{full_name}.gemspec")
          next if File.exist?(target_spec_path)

          FS.mkdir_p(target_spec_dir)
          FS.clonefile(spec_path, target_spec_path)
        end
      end

      def write_binstubs(entry, cache, bundle_path)
        extracted = extracted_path_for_entry(entry, cache)
        gemspec = load_gemspec(extracted, entry.spec, cache)
        prepared = PreparedGem.new(
          spec: entry.spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )
        Installer::Linker.write_binstubs(prepared, bundle_path)
      end

      def load_gemspec(extracted_path, spec, cache)
        cached = load_cached_gemspec(spec, cache, extracted_path)
        return cached if cached

        inbound = cache.inbound_path(spec)
        return nil unless File.exist?(inbound)

        begin
          metadata = GemPkg::Package.new.read_metadata(inbound)
          cache_gemspec(spec, metadata, cache)
          metadata
        rescue StandardError
          nil
        end
      end

      def load_cached_gemspec(spec, cache, extracted_path)
        path = cache.spec_cache_path(spec)
        return nil unless File.exist?(path)

        data = File.binread(path)
        gemspec = if data.start_with?("---")
          Gem::Specification.from_yaml(data)
        else
          begin
            Marshal.load(data)
          rescue StandardError
            Gem::Specification.from_yaml(data)
          end
        end
        return gemspec if cached_gemspec_valid?(gemspec, extracted_path)

        nil
      rescue StandardError
        nil
      end

      def cached_gemspec_valid?(gemspec, extracted_path)
        return false unless gemspec.respond_to?(:require_paths)

        require_paths = Array(gemspec.require_paths).reject(&:empty?)
        return true if require_paths.empty?

        require_paths.all? do |rp|
          dir = File.join(extracted_path, rp)
          next false unless Dir.exist?(dir)

          # Heuristic for stale cached metadata seen in some gems:
          # `require_paths=["lib"]` while all entries live under a
          # hyphenated nested directory (e.g. lib/concurrent-ruby).
          if rp == "lib"
            entries = Dir.children(dir)
            top_level_rb = entries.any? do |entry|
              path = File.join(dir, entry)
              File.file?(path) && entry.end_with?(".rb")
            end
            next true if top_level_rb

            nested_dirs = entries.select { |entry| File.directory?(File.join(dir, entry)) }
            next false if nested_dirs.any? { |entry| entry.include?("-") }
          end

          true
        end
      end

      def cache_gemspec(spec, gemspec, cache)
        path = cache.spec_cache_path(spec)
        FS.atomic_write(path, gemspec.to_yaml)
      rescue StandardError
        # Non-fatal: we'll read metadata from .gem next time.
      end

      # --- Lockfile + runtime config ---

      def write_lockfile(resolved, gemfile, lockfile = nil)
        specs, sources, preserved_layout = build_lockfile_specs_and_sources(resolved, gemfile, lockfile)

        lockfile_data = Lockfile::LockfileData.new(
          specs: specs,
          dependencies: build_lockfile_dependencies(gemfile, lockfile),
          platforms: preserved_layout && lockfile ? Array(lockfile.platforms) : build_lockfile_platforms(specs, lockfile),
          sources: sources,
          bundler_version: lockfile&.bundler_version || Scint::VERSION,
          ruby_version: lockfile&.ruby_version || gemfile.ruby_version,
          checksums: preserved_layout && lockfile ? lockfile.checksums : build_lockfile_checksums(specs, lockfile),
        )

        content = Lockfile::Writer.write(lockfile_data)
        FS.atomic_write("Gemfile.lock", content)
      end

      def build_lockfile_specs_and_sources(resolved, gemfile, lockfile)
        resolved_for_lockfile = filter_lockfile_specs(resolved)

        if preserve_existing_lockfile_specs?(resolved_for_lockfile, lockfile)
          specs = Array(lockfile.specs).map { |spec| normalize_lockfile_spec(spec) }
          sources = uniq_sources(Array(lockfile.sources))
          return [specs, sources, true]
        end

        dependency_sources = dependency_sources_from_gemfile(gemfile, lockfile)
        existing_sources = Array(lockfile&.sources)
        candidate_sources = uniq_sources(existing_sources + dependency_sources.values)

        rubygems_uris = collect_lockfile_rubygems_uris(gemfile)
        if rubygems_uris.empty? && candidate_sources.none? { |src| src.is_a?(Source::Rubygems) }
          rubygems_uris << "https://rubygems.org"
        end
        rubygems_uris.each do |uri|
          source = find_matching_rubygems_source(candidate_sources, uri)
          candidate_sources << Source::Rubygems.new(remotes: [uri]) unless source
        end
        candidate_sources = uniq_sources(candidate_sources)

        lock_source_by_full, lock_source_by_name_version = lockfile_sources_by_spec_key(lockfile)
        default_rubygems_source = candidate_sources.find { |src| src.is_a?(Source::Rubygems) }

        specs = resolved_for_lockfile.map do |spec|
          normalized = normalize_resolved_spec(spec)
          source = source_for_spec(
            normalized,
            dependency_sources: dependency_sources,
            candidate_sources: candidate_sources,
            lock_source_by_full: lock_source_by_full,
            lock_source_by_name_version: lock_source_by_name_version,
            fallback: default_rubygems_source,
          )
          normalized.merge(source: source)
        end

        sources = uniq_sources(specs.map { |spec| spec[:source] }.compact)
        if sources.empty?
          fallback = default_rubygems_source || Source::Rubygems.new(remotes: ["https://rubygems.org"])
          sources = [fallback]
          specs.each { |spec| spec[:source] = fallback }
        end

        [specs, sources, false]
      end

      def filter_lockfile_specs(specs)
        specs.reject do |spec|
          name = spec.is_a?(Hash) ? spec[:name].to_s : spec.name.to_s
          name == "scint"
        end
      end

      def preserve_existing_lockfile_specs?(resolved, lockfile)
        return false unless lockfile && lockfile.respond_to?(:specs)

        wanted = resolved.map { |spec| [spec.name.to_s, spec.version.to_s] }.uniq
        return false if wanted.empty?

        available = Set.new
        Array(lockfile.specs).each do |spec|
          available << [spec[:name].to_s, spec[:version].to_s]
        end

        wanted.all? { |tuple| available.include?(tuple) }
      end

      def normalize_lockfile_spec(spec)
        if spec.is_a?(Hash)
          {
            name: spec[:name],
            version: spec[:version],
            platform: spec[:platform] || "ruby",
            dependencies: spec[:dependencies] || [],
            source: spec[:source],
            checksum: spec[:checksum],
          }
        else
          {
            name: spec.name,
            version: spec.version,
            platform: spec.platform || "ruby",
            dependencies: spec.dependencies || [],
            source: spec.source,
            checksum: spec.respond_to?(:checksum) ? spec.checksum : nil,
          }
        end
      end

      def normalize_resolved_spec(spec)
        if spec.is_a?(Hash)
          {
            name: spec[:name],
            version: spec[:version],
            platform: spec[:platform] || "ruby",
            dependencies: spec[:dependencies] || [],
            source: spec[:source],
            checksum: spec[:checksum],
          }
        else
          {
            name: spec.name,
            version: spec.version,
            platform: spec.platform || "ruby",
            dependencies: spec.dependencies || [],
            source: spec.source,
            checksum: spec.respond_to?(:checksum) ? spec.checksum : nil,
          }
        end
      end

      def collect_lockfile_rubygems_uris(gemfile)
        uris = gemfile.sources
          .select { |src| src[:type] == :rubygems && src[:uri] }
          .map { |src| src[:uri].to_s }

        gemfile.dependencies.each do |dep|
          inline = dep.source_options[:source]
          uris << inline.to_s if inline
        end

        uris.uniq
      end

      def dependency_sources_from_gemfile(gemfile, lockfile)
        existing_sources = Array(lockfile&.sources)
        out = {}

        gemfile.dependencies.each do |dep|
          opts = dep.source_options

          source =
            if opts[:path]
              find_matching_path_source(existing_sources, opts[:path]) ||
                Source::Path.new(path: opts[:path], name: dep.name)
            elsif opts[:git]
              matched = find_matching_git_source(existing_sources, opts)
              Source::Git.new(
                uri: opts[:git],
                revision: matched&.revision,
                ref: opts[:ref] || matched&.ref,
                branch: opts[:branch] || matched&.branch,
                tag: opts[:tag] || matched&.tag,
                submodules: opts.fetch(:submodules, matched&.submodules),
                glob: matched&.glob,
                name: dep.name,
              )
            elsif opts[:source]
              find_matching_rubygems_source(existing_sources, opts[:source]) ||
                Source::Rubygems.new(remotes: [opts[:source]])
            end

          out[dep.name] = source if source
        end

        out
      end

      def lockfile_sources_by_spec_key(lockfile)
        by_full = {}
        by_name_version = {}

        Array(lockfile&.specs).each do |spec|
          source = spec[:source]
          next unless source

          name = spec[:name].to_s
          version = spec[:version].to_s
          platform = (spec[:platform] || "ruby").to_s

          by_full[[name, version, platform]] = source
          by_name_version[[name, version]] ||= source
        end

        [by_full, by_name_version]
      end

      def source_for_spec(spec, dependency_sources:, candidate_sources:, lock_source_by_full:, lock_source_by_name_version:, fallback:)
        key_full = [spec[:name].to_s, spec[:version].to_s, spec[:platform].to_s]
        locked_source = lock_source_by_full[key_full] || lock_source_by_name_version[key_full[0, 2]]
        return locked_source if locked_source

        dep_source = dependency_sources[spec[:name].to_s]
        return dep_source if dep_source

        spec_source = spec[:source]
        source = find_matching_source(candidate_sources, spec_source)
        return source if source

        spec_source = spec_source.to_s
        if git_source?(spec_source)
          source = Source::Git.new(uri: spec_source, name: spec[:name])
          candidate_sources << source
          return source
        elsif spec_source.start_with?("/") || spec_source.start_with?(".")
          source = Source::Path.new(path: spec_source, name: spec[:name])
          candidate_sources << source
          return source
        end

        if rubygems_source_uri?(spec_source.to_s)
          source = Source::Rubygems.new(remotes: [spec_source.to_s])
          candidate_sources << source
          return source
        end

        fallback
      end

      def find_matching_source(sources, source_ref)
        return nil if source_ref.nil?

        sources.find do |source|
          source_matches?(source, source_ref)
        end
      end

      def source_matches?(source, source_ref)
        return true if source.equal?(source_ref)
        return true if source == source_ref

        source_key = normalize_source_key(source_ref)
        return false unless source_key

        if source.is_a?(Source::Rubygems)
          source.remotes.any? { |remote| normalize_source_key(remote) == source_key }
        elsif source.respond_to?(:uri)
          normalize_source_key(source.uri) == source_key
        else
          normalize_source_key(source) == source_key
        end
      end

      def normalize_source_key(source_ref)
        return nil if source_ref.nil?

        raw =
          if source_ref.respond_to?(:uri)
            source_ref.uri.to_s
          elsif source_ref.respond_to?(:path)
            source_ref.path.to_s
          else
            source_ref.to_s
          end
        return nil if raw.empty?

        if raw.match?(%r{\Ahttps?://}i)
          raw = raw.sub(%r{\Ahttps?://}i, "")
          raw = raw.sub(%r{\.git/?\z}i, "")
          raw.chomp("/").downcase
        elsif raw.start_with?("/") || raw.start_with?(".")
          File.expand_path(raw)
        else
          raw.sub(%r{\.git/?\z}i, "").chomp("/").downcase
        end
      end

      def find_matching_rubygems_source(sources, uri)
        sources.find do |source|
          source.is_a?(Source::Rubygems) && source.remotes.any? { |remote| source_matches?(remote, uri) }
        end
      end

      def find_matching_path_source(sources, path)
        sources.find { |source| source.is_a?(Source::Path) && source_matches?(source, path) }
      end

      def find_matching_git_source(sources, opts)
        candidates = sources.select { |source| source.is_a?(Source::Git) && source_matches?(source, opts[:git]) }
        return nil if candidates.empty?

        candidates.find { |source| git_source_options_match?(source, opts) } || candidates.first
      end

      def git_source_options_match?(source, opts)
        return false if opts[:branch] && source.branch.to_s != opts[:branch].to_s
        return false if opts[:tag] && source.tag.to_s != opts[:tag].to_s
        return false if opts[:ref] && source.ref.to_s != opts[:ref].to_s

        true
      end

      def uniq_sources(sources)
        out = []
        sources.each do |source|
          next unless source
          out << source unless out.any? { |existing| existing.eql?(source) }
        end
        out
      end

      def build_lockfile_dependencies(gemfile, lockfile)
        locked = lockfile&.dependencies || {}
        gemfile.dependencies.map do |dep|
          locked_dep = locked[dep.name]
          {
            name: dep.name,
            version_reqs: dep.version_reqs,
            pinned: !!(locked_dep && locked_dep[:pinned]),
          }
        end
      end

      def build_lockfile_platforms(specs, lockfile)
        platforms = Set.new(Array(lockfile&.platforms))
        specs.each do |spec|
          platform = spec[:platform] || "ruby"
          platforms << platform
        end
        platforms << "ruby"
        platforms.to_a
      end

      def build_lockfile_checksums(specs, lockfile)
        existing = lockfile&.checksums
        checksums = {}

        specs.each do |spec|
          key = lockfile_spec_checksum_key(spec)
          checksum = spec[:checksum]
          if checksum && !Array(checksum).empty?
            checksums[key] = Array(checksum)
          elsif existing&.key?(key)
            checksums[key] = Array(existing[key])
          end
        end

        return nil if checksums.empty?

        checksums
      end

      def lockfile_spec_checksum_key(spec)
        name = spec[:name]
        version = spec[:version]
        platform = spec[:platform] || "ruby"
        platform == "ruby" ? "#{name}-#{version}" : "#{name}-#{version}-#{platform}"
      end

      def write_runtime_config(resolved, bundle_path)
        ruby_dir = File.join(bundle_path, "ruby",
                             RUBY_VERSION.split(".")[0, 2].join(".") + ".0")

        data = {}
        resolved.each do |spec|
          full = spec_full_name(spec)
          gem_dir = File.join(ruby_dir, "gems", full)
          spec_file = File.join(ruby_dir, "specifications", "#{full}.gemspec")
          require_paths = read_require_paths(spec_file)
          load_paths = require_paths
            .map { |rp| File.join(gem_dir, rp) }
            .select { |path| Dir.exist?(path) }

          default_lib = File.join(gem_dir, "lib")
          load_paths << default_lib if load_paths.empty? && Dir.exist?(default_lib)
          load_paths.concat(detect_nested_lib_paths(gem_dir))
          load_paths.uniq!

          # Add ext load path if extensions exist
          ext_dir = File.join(ruby_dir, "extensions",
                              Platform.gem_arch, Platform.extension_api_version, full)
          load_paths << ext_dir if Dir.exist?(ext_dir)

          data[spec.name] = {
            version: spec.version.to_s,
            load_paths: load_paths,
          }
        end

        lock_path = File.join(bundle_path, RUNTIME_LOCK)
        FS.atomic_write(lock_path, Marshal.dump(data))
      end

      def read_require_paths(spec_file)
        return ["lib"] unless File.exist?(spec_file)

        gemspec = Gem::Specification.load(spec_file)
        paths = Array(gemspec&.require_paths).reject(&:empty?)
        paths.empty? ? ["lib"] : paths
      rescue StandardError
        ["lib"]
      end

      def detect_nested_lib_paths(gem_dir)
        lib_dir = File.join(gem_dir, "lib")
        return [] unless Dir.exist?(lib_dir)

        children = Dir.children(lib_dir)
        top_level_rb = children.any? do |entry|
          path = File.join(lib_dir, entry)
          File.file?(path) && entry.end_with?(".rb")
        end
        return [] if top_level_rb

        children
          .map { |entry| File.join(lib_dir, entry) }
          .select { |path| File.directory?(path) }
      end

      def spec_full_name(spec)
        base = "#{spec.name}-#{spec.version}"
        plat = spec.respond_to?(:platform) ? spec.platform : nil
        (plat.nil? || plat.to_s == "ruby" || plat.to_s.empty?) ? base : "#{base}-#{plat}"
      end

      def elapsed_ms_since(start_time)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        (elapsed * 1000).round
      end

      def force_purge_artifacts(resolved, bundle_path, cache)
        ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
        ext_root = File.join(ruby_dir, "extensions", Platform.gem_arch, Platform.extension_api_version)

        resolved.each do |spec|
          full = cache.full_name(spec)

          # Global cache artifacts.
          FileUtils.rm_f(cache.inbound_path(spec))
          FileUtils.rm_rf(cache.extracted_path(spec))
          FileUtils.rm_f(cache.spec_cache_path(spec))
          FileUtils.rm_rf(cache.ext_path(spec))

          # Local bundle artifacts.
          FileUtils.rm_rf(File.join(ruby_dir, "gems", full))
          FileUtils.rm_f(File.join(ruby_dir, "specifications", "#{full}.gemspec"))
          FileUtils.rm_rf(File.join(ext_root, full))
        end

        # Binstubs are regenerated from gemspec metadata.
        FileUtils.rm_rf(File.join(bundle_path, "bin"))
        FileUtils.rm_rf(File.join(ruby_dir, "bin"))
        FileUtils.rm_f(File.join(bundle_path, RUNTIME_LOCK))
      end

      def format_elapsed(elapsed_ms)
        return "#{elapsed_ms}ms" if elapsed_ms <= 1000

        "#{(elapsed_ms / 1000.0).round(2)}s"
      end

      def format_run_footer(elapsed_ms, worker_count)
        workers = worker_count.to_i
        noun = workers == 1 ? "worker" : "workers"
        "#{format_elapsed(elapsed_ms)}, #{workers} #{noun} used"
      end

      def emit_network_error_details(error)
        return unless error.is_a?(NetworkError)

        headers = error.response_headers
        body = error.response_body.to_s
        return if (headers.nil? || headers.empty?) && body.empty?

        if headers && !headers.empty?
          $stderr.puts "    headers:"
          headers.sort.each do |key, value|
            $stderr.puts "      #{key}: #{value}"
          end
        end

        return if body.empty?

        $stderr.puts "    body:"
        body.each_line do |line|
          $stderr.puts "      #{line.rstrip}"
        end
      end

      def warn_missing_bundle_gitignore_entry
        path = ".gitignore"
        return unless File.file?(path)
        return if gitignore_has_bundle_entry?(path)

        $stderr.puts "#{YELLOW}Warning: .gitignore exists but does not ignore .bundle (add `.bundle/`).#{RESET}"
      end

      def gitignore_has_bundle_entry?(path)
        File.foreach(path) do |line|
          entry = line.strip
          next if entry.empty? || entry.start_with?("#", "!")

          normalized = entry.sub(%r{\A\./}, "")
          return true if normalized.match?(%r{\A(?:\*\*/)?/?\.bundle(?:/.*)?\z})
        end
        false
      rescue StandardError
        false
      end

      def install_breakdown(**counts)
        parts = counts.filter_map do |label, n|
          next if n.zero?
          color = (label == :failed) ? RED : ""
          reset = color.empty? ? "" : RESET
          "#{color}#{n} #{label}#{reset}"
        end
        parts.empty? ? "" : " (#{parts.join(", ")})"
      end

      def parse_options
        i = 0
        while i < @argv.length
          case @argv[i]
          when "--jobs", "-j"
            @jobs = @argv[i + 1]&.to_i
            i += 2
          when "--path"
            @path = @argv[i + 1]
            i += 2
          when "--verbose"
            @verbose = true
            i += 1
          when "--force", "-f"
            @force = true
            i += 1
          else
            i += 1
          end
        end
      end
    end
  end
end
