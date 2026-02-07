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
        parse_options
      end

      def run
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        cache = Scint::Cache::Layout.new
        bundle_path = @path || ENV["BUNDLER_PATH"] || ".bundle"
        bundle_path = File.expand_path(bundle_path)
        worker_count = @jobs || [Platform.cpu_count * 2, 50].min
        per_type_limits = install_task_limits(worker_count)

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
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems)}. #{DIM}(#{format_elapsed(elapsed_ms)})#{RESET}"
            return 0
          end

          # 8. Build a dependency-aware task graph:
          # download -> link_files -> build_ext -> binstub (where applicable).
          compiled_gems = enqueue_install_dag(scheduler, plan, cache, bundle_path, scheduler.progress)

          # 9. Wait for everything
          scheduler.wait_all

          errors = scheduler.errors.dup
          stats = scheduler.stats
          if errors.any?
            $stderr.puts "#{RED}Some gems failed to install:#{RESET}"
            errors.each do |err|
              $stderr.puts "  #{BOLD}#{err[:name]}#{RESET}: #{err[:error].message}"
            end
          elsif stats[:failed] > 0
            $stderr.puts "#{YELLOW}Warning: #{stats[:failed]} jobs failed but no error details captured#{RESET}"
          end

          elapsed_ms = elapsed_ms_since(start_time)
          failed = errors.filter_map { |e| e[:name] }.uniq
          failed_count = failed.size
          failed_count = 1 if failed_count.zero? && stats[:failed] > 0
          installed_total = [total_gems - failed_count, 0].max
          has_failures = errors.any? || stats[:failed] > 0

          if has_failures
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{RED}Bundle failed!#{RESET} #{installed_total}/#{total_gems} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems, failed: failed_count)}. #{DIM}(#{format_elapsed(elapsed_ms)})#{RESET}"
            1
          else
            # 10. Write lockfile + runtime config only for successful installs
            write_lockfile(resolved, gemfile)
            write_runtime_config(resolved, bundle_path)
            warn_missing_bundle_gitignore_entry
            $stdout.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems)}. #{DIM}(#{format_elapsed(elapsed_ms)})#{RESET}"
            0
          end
        ensure
          scheduler.shutdown
        end
      end

      private

      # --- Spec adjustment ---

      # Post-resolution pass: remove bundler (we replace it) and inject scint.
      # This ensures `require "bundler/setup"` loads our shim, and scint
      # appears in the gem list just like bundler does for stock bundler.
      def adjust_meta_gems(resolved)
        resolved = resolved.reject { |s| s.name == "bundler" }

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
        resolved << scint_spec

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

      # Install scint (or other built-in gems) by symlinking to our own lib
      # and writing a minimal gemspec. No download or extraction needed.
      def install_builtin_gem(entry, bundle_path)
        spec = entry.spec
        ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
        full_name = spec_full_name(spec)

        # Symlink gem dir → scint's lib parent
        gem_dest = File.join(ruby_dir, "gems", full_name)
        scint_root = File.expand_path("../../..", __FILE__)
        unless File.exist?(gem_dest)
          FS.mkdir_p(File.dirname(gem_dest))
          File.symlink(scint_root, gem_dest)
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
        return if Dir.exist?(git_dir)

        FS.mkdir_p(File.dirname(git_dir))
        system("git", "clone", "--bare", source.uri.to_s, git_dir,
               [:out, :err] => File::NULL)
      end

      def resolve(gemfile, lockfile, cache)
        # If lockfile is up-to-date, use its specs directly
        if lockfile && lockfile_current?(gemfile, lockfile)
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
            gemspec = find_gemspec(opts[:path], dep.name)
            if gemspec
              version = gemspec.version.to_s
              deps = gemspec.dependencies
                .select { |d| d.type == :runtime }
                .map { |d| [d.name, d.requirement.to_s] }
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

      def find_gemspec(path, gem_name)
        return nil unless Dir.exist?(path)

        # Look for exact match first, then any gemspec
        candidates = [
          File.join(path, "#{gem_name}.gemspec"),
          *Dir.glob(File.join(path, "*.gemspec")),
        ]

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
        gemfile.dependencies.all? { |d| locked_names.include?(d.name) }
      end

      def lockfile_to_resolved(lockfile)
        lockfile.specs.map do |ls|
          source = ls[:source]
          source_value =
            if source.is_a?(Source::Rubygems)
              source.uri.to_s
            else
              source
            end

          ResolvedSpec.new(
            name: ls[:name],
            version: ls[:version],
            platform: ls[:platform],
            dependencies: ls[:dependencies],
            source: source_value,
            has_extensions: false,
            remote_uri: nil,
            checksum: ls[:checksum],
          )
        end
      end

      def download_gem(entry, cache)
        spec = entry.spec
        source = spec.source
        if git_source?(source)
          prepare_git_source(entry, cache)
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
          pool = Downloader::Pool.new(size: 1, credentials: @credentials)
          pool.download(download_uri, dest_path)
          pool.close
        end

        # Extract
        extracted = cache.extracted_path(spec)
        unless Dir.exist?(extracted)
          FS.mkdir_p(extracted)
          pkg = GemPkg::Package.new
          result = pkg.extract(dest_path, extracted)
          cache_gemspec(spec, result[:gemspec], cache)
        end
      end

      def git_source?(source)
        return true if source.is_a?(Source::Git)

        source_str = source.to_s
        source_str.end_with?(".git") || source_str.include?(".git/")
      end

      def prepare_git_source(entry, cache)
        spec = entry.spec
        source = spec.source
        uri, revision = git_source_ref(source)

        bare_repo = cache.git_path(uri)

        # Serialize all git operations per bare repo — git uses index.lock
        # and can't handle concurrent checkouts from the same repo.
        git_mutex_for(bare_repo).synchronize do
          clone_git_repo(uri, bare_repo) unless Dir.exist?(bare_repo)

          extracted = cache.extracted_path(spec)
          return if Dir.exist?(extracted)

          tmp = "#{extracted}.#{Process.pid}.#{Thread.current.object_id}.tmp"
          begin
            FileUtils.rm_rf(tmp)
            FS.mkdir_p(tmp)

            cmd = ["git", "--git-dir", bare_repo, "--work-tree", tmp, "checkout", "-f", revision, "--", "."]
            _out, err, status = Open3.capture3(*cmd)
            unless status.success?
              raise InstallError, "Git checkout failed for #{spec.name} (#{uri}@#{revision}): #{err.to_s.strip}"
            end

            FS.atomic_move(tmp, extracted)
          ensure
            FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
          end
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
        _out, err, status = Open3.capture3("git", "clone", "--bare", uri.to_s, bare_repo)
        unless status.success?
          raise InstallError, "Git clone failed for #{uri}: #{err.to_s.strip}"
        end
      end

      def install_task_limits(worker_count)
        # Leave headroom for build_ext and binstub lanes so link/download
        # throughput cannot fully starve them.
        io_cpu_limit = [worker_count - 2, 1].max
        {
          download: io_cpu_limit,
          link: io_cpu_limit,
          build_ext: 1,
          binstub: 1,
        }
      end

      # Enqueue dependency-aware install tasks so compile/binstub can run
      # concurrently with link/download once prerequisites are satisfied.
      def enqueue_install_dag(scheduler, plan, cache, bundle_path, progress = nil)
        link_job_by_key = {}
        link_job_by_name = {}
        build_job_by_key = {}

        plan.each do |entry|
          case entry.action
          when :skip
            next
          when :builtin
            install_builtin_gem(entry, bundle_path)
            next
          when :download
            download_id = scheduler.enqueue(:download, entry.spec.name,
                                            -> { download_gem(entry, cache) })
            link_id = scheduler.enqueue(:link, entry.spec.name,
                                        -> { link_gem_files(entry, cache, bundle_path) },
                                        depends_on: [download_id])
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
                                       -> { build_extensions(entry, cache, bundle_path, progress) },
                                       depends_on: depends_on)
          build_job_by_key[key] = build_id
        end

        plan.each do |entry|
          next if entry.action == :skip || entry.action == :builtin

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

        build_job_by_key.size
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

      def enqueue_builds(scheduler, entries, cache, bundle_path)
        enqueued = 0
        entries.each do |entry|
          extracted = extracted_path_for_entry(entry, cache)
          next unless Installer::ExtensionBuilder.buildable_source_dir?(extracted)

          scheduler.enqueue(:build_ext, entry.spec.name,
                            -> { build_extensions(entry, cache, bundle_path) })
          enqueued += 1
        end
        enqueued
      end

      def extracted_path_for_entry(entry, cache)
        source_str = entry.spec.source.to_s
        if source_str.start_with?("/") && Dir.exist?(source_str)
          source_str
        else
          entry.cached_path || cache.extracted_path(entry.spec)
        end
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
      end

      def build_extensions(entry, cache, bundle_path, progress = nil)
        extracted = entry.cached_path || cache.extracted_path(entry.spec)
        gemspec = load_gemspec(extracted, entry.spec, cache)

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
          output_tail: ->(lines) { progress&.on_build_tail(entry.spec.name, lines) },
        )
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

      def write_lockfile(resolved, gemfile)
        sources = []

        # Build source objects for path and git gems
        gemfile.dependencies.each do |dep|
          opts = dep.source_options
          if opts[:path]
            sources << Source::Path.new(path: opts[:path], name: dep.name)
          elsif opts[:git]
            sources << Source::Git.new(
              uri: opts[:git],
              branch: opts[:branch],
              tag: opts[:tag],
              ref: opts[:ref],
            )
          end
        end

        # Build rubygems sources -- collect all unique URIs
        rubygems_uris = gemfile.sources
          .select { |s| s[:type] == :rubygems }
          .map { |s| s[:uri] }
          .uniq

        # Group URIs that share specs into one Source::Rubygems each.
        # The default source gets all remotes that aren't a separate scoped source.
        scoped_uris = Set.new
        gemfile.dependencies.each do |dep|
          src = dep.source_options[:source]
          scoped_uris << src if src
        end

        # Each scoped URI gets its own source object
        scoped_uris.each do |uri|
          sources << Source::Rubygems.new(remotes: [uri])
        end

        # Default rubygems source with remaining remotes
        default_remotes = rubygems_uris.reject { |u| scoped_uris.include?(u) }
        default_remotes = ["https://rubygems.org"] if default_remotes.empty?
        sources << Source::Rubygems.new(remotes: default_remotes)

        lockfile_data = Lockfile::LockfileData.new(
          specs: resolved,
          dependencies: gemfile.dependencies.map { |d| { name: d.name, version_reqs: d.version_reqs } },
          platforms: [Platform.local_platform.to_s, "ruby"].uniq,
          sources: sources,
          bundler_version: Scint::VERSION,
          ruby_version: nil,
          checksums: nil,
        )

        content = Lockfile::Writer.write(lockfile_data)
        FS.atomic_write("Gemfile.lock", content)
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
