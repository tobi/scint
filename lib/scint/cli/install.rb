# frozen_string_literal: true

require_relative "../errors"
require_relative "../fs"
require_relative "../platform"
require_relative "../spec_utils"
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
require_relative "../cache/manifest"
require_relative "../cache/metadata_store"
require_relative "../cache/validity"
require_relative "../installer/planner"
require_relative "../installer/linker"
require_relative "../installer/preparer"
require_relative "../installer/extension_builder"
require_relative "../vendor/pub_grub"
require_relative "../resolver/provider"
require_relative "../resolver/resolver"
require_relative "../credentials"
require_relative "../bundle"
require "open3"
require "set"
require "pathname"

module Scint
  module CLI
    class Install
      RUNTIME_LOCK = "scint.lock.marshal"

      def initialize(argv = [], without: nil, with: nil, output: $stderr)
        @argv = argv
        @jobs = nil
        @path = nil
        @verbose = false
        @force = false
        @without_groups = nil
        @with_groups = nil
        @output = output
        @download_pool = nil
        @download_pool_lock = Thread::Mutex.new
        @gemspec_cache = {}
        @gemspec_cache_lock = Thread::Mutex.new
        parse_options
        # Allow programmatic override (for tests)
        @without_groups = Array(without).map(&:to_sym) if without
        @with_groups = Array(with).map(&:to_sym) if with
      end

      def bundle
        @bundle ||= Scint::Bundle.new(".", without: @without_groups, with: @with_groups)
      end

      def _tmark(label, t0)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @output.puts "  [timing] #{label}: #{((now - t0) * 1000).round}ms" if ENV["SCINT_TIMING"]
        now
      end

      def run
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _t = start_time

        cache = Scint::Cache::Layout.new
        cache_telemetry = Scint::Cache::Telemetry.new
        bundle_path = @path || ENV["BUNDLER_PATH"] || ".bundle"
        bundle_display = display_bundle_path(bundle_path)
        bundle_path = File.expand_path(bundle_path)
        worker_count = [(@jobs || [Platform.cpu_count * 2, 50].min).to_i, 1].max
        compile_slots = compile_slots_for(worker_count)
        git_slots = git_slots_for(worker_count)
        per_type_limits = install_task_limits(worker_count, compile_slots, git_slots)
        cache_display = cache.root.sub(Dir.home, "~")
        @output.puts "💎 #{BLUE}Scintellating#{RESET} Gemfile"
        @output.puts "  #{DIM}into#{RESET}  #{BOLD}#{bundle_display}#{RESET}"
        @output.puts "  #{DIM}cache#{RESET} #{cache_display}"
        @output.puts "  #{DIM}scint #{VERSION}, ruby #{RUBY_VERSION}#{RESET}"
        @output.puts

        # 0. Build credential store and Bundle instance
        @credentials = Credentials.new
        @bundle = Scint::Bundle.new(".", without: @without_groups, with: @with_groups, credentials: @credentials)

        # 1. Start the scheduler with 1 worker — scale up dynamically
        scheduler = Scheduler.new(max_workers: worker_count, fail_fast: true, per_type_limits: per_type_limits,
                                  progress: Progress.new(output: @output))
        scheduler.start

        begin
          _t = _tmark("startup", _t)
          # 2. Parse Gemfile
          gemfile = bundle.gemfile

          # Register credentials from Gemfile sources and dependencies
          @credentials.register_sources(gemfile.sources)
          @credentials.register_dependencies(gemfile.dependencies)

          # Scale workers based on dependency count
          dep_count = gemfile.dependencies.size
          scheduler.scale_workers(dep_count)

          _t = _tmark("parse_gemfile", _t)
          # 3. Enqueue index fetches for all sources immediately
          gemfile.sources.each do |source|
            scheduler.enqueue(:fetch_index, source[:uri] || source.to_s,
                              -> { bundle.send(:fetch_index, source, cache) })
          end

          # 4. Parse lockfile if it exists
          lockfile = bundle.lockfile
          @credentials.register_lockfile_sources(lockfile.sources) if lockfile

          # 5. Enqueue git clones for git sources
          git_sources = gemfile.sources.select { |s| s.is_a?(Source::Git) }
          git_sources.each do |source|
            scheduler.enqueue(:git_clone, source.uri,
                              -> { bundle.send(:clone_git_source, source, cache) })
          end

          _t = _tmark("enqueue_fetches", _t)
          # 6. Wait for index fetches, then resolve
          scheduler.wait_for(:fetch_index)
          _t = _tmark("wait_index", _t)
          scheduler.wait_for(:git_clone)
          _t = _tmark("wait_git", _t)

          progress = scheduler.progress
          progress.on_enqueue(-1, :resolve, "dependencies")
          progress.on_start(-1, :resolve, "dependencies")
          resolved = resolve(gemfile, lockfile, cache)
          resolved = dedupe_resolved_specs(adjust_meta_gems(resolved))
          resolved = filter_excluded_gems(resolved, gemfile)
          force_purge_artifacts(resolved, bundle_path, cache) if @force
          progress.on_complete(-1, :resolve, "dependencies")

          _t = _tmark("resolve", _t)
          # 7. Plan: diff resolved vs installed
          plan = Installer::Planner.plan(resolved, bundle_path, cache, telemetry: cache_telemetry)
          total_gems = resolved.size
          updated_gems = plan.count { |e| e.action != :skip }
          cached_gems = total_gems - updated_gems
          to_install = plan.reject { |e| e.action == :skip }
          _t = _tmark("plan", _t)

          # Scale up for download/install phase based on actual work count
          scheduler.scale_workers(to_install.size)

          # Warm-cache accelerator: pre-materialize cache-backed gem trees in
          # batches so install workers avoid one cp process per gem.
          bulk_prelink_gem_files(to_install, cache, bundle_path)
          _t = _tmark("prelink", _t)

          if to_install.empty?
            # Keep lock artifacts aligned even when everything is already installed.
            write_lockfile(resolved, gemfile, lockfile)
            write_runtime_config(resolved, bundle_path)
            elapsed_ms = elapsed_ms_since(start_time)
            worker_count = scheduler.stats[:workers]
            warn_missing_bundle_gitignore_entry
            @output.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
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
            @output.puts "#{RED}Some gems failed to install:#{RESET}"
            errors.each do |err|
              error = err[:error]
              @output.puts "  #{BOLD}#{err[:name]}#{RESET}: #{error.message}"
              emit_network_error_details(error)
            end
          elsif stats[:failed] > 0
            @output.puts "#{YELLOW}Warning: #{stats[:failed]} jobs failed but no error details captured#{RESET}"
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
            @output.puts "\n#{RED}Bundle failed!#{RESET} #{installed_total}/#{total_gems} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems, failed: failed_count)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
            1
          else
            # 10. Write lockfile + runtime config only for successful installs
            write_lockfile(resolved, gemfile, lockfile)
            write_runtime_config(resolved, bundle_path)
            warn_missing_bundle_gitignore_entry
            @output.puts "\n#{GREEN}#{total_gems}#{RESET} gems installed total#{install_breakdown(cached: cached_gems, updated: updated_gems, compiled: compiled_gems)}. #{DIM}(#{format_run_footer(elapsed_ms, worker_count)})#{RESET}"
            0
          end
        ensure
          begin
            cache_telemetry.warn_if_needed(cache_root: cache.root)
          ensure
            begin
              scheduler.shutdown
            ensure
              close_download_pool
            end
          end
        end
      end

      private

      # Install scint into the bundle by copying our own lib tree.
      # No download needed — we know exactly where we are.
      def install_builtin_gem(entry, bundle_path)
        spec = entry.spec
        ruby_dir = Platform.ruby_install_dir(bundle_path)
        full_name = SpecUtils.full_name(spec)
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

      # --- Delegated to Bundle (resolution + helpers) ---

      def resolve(gemfile, lockfile, cache)
        if lockfile &&
           lockfile_current?(gemfile, lockfile) &&
           lockfile_dependency_graph_valid?(lockfile) &&
           lockfile_git_source_mapping_valid?(lockfile, cache)
          return lockfile_to_resolved(lockfile)
        end

        bundle.send(:run_full_resolve, gemfile, lockfile, cache)
      end

      def adjust_meta_gems(resolved)
        bundle.send(:adjust_meta_gems, resolved)
      end

      def dedupe_resolved_specs(resolved)
        bundle.send(:dedupe_resolved_specs, resolved)
      end

      def filter_excluded_gems(resolved, gemfile)
        bundle.send(:filter_excluded_gems, resolved, gemfile)
      end

      def excluded_gem_names(gemfile, resolved: nil)
        bundle.excluded_gem_names(gemfile, resolved: resolved)
      end

      def lockfile_current?(gemfile, lockfile)
        bundle.send(:lockfile_current?, gemfile, lockfile)
      end

      def lockfile_dependency_graph_valid?(lockfile)
        bundle.send(:lockfile_dependency_graph_valid?, lockfile)
      end

      def lockfile_git_source_mapping_valid?(lockfile, cache)
        bundle.send(:lockfile_git_source_mapping_valid?, lockfile, cache)
      end

      def lockfile_to_resolved(lockfile)
        bundle.send(:lockfile_to_resolved, lockfile)
      end

      def find_gemspec(path, gem_name, glob: nil)
        bundle.send(:find_gemspec, path, gem_name, glob: glob)
      end

      def find_git_gemspec(git_repo, revision, gem_name, glob: nil)
        bundle.send(:find_git_gemspec, git_repo, revision, gem_name, glob: glob)
      end

      def build_git_path_gems_for_revision(git_repo, revision, glob: nil, source_desc: nil)
        bundle.send(:build_git_path_gems_for_revision, git_repo, revision, glob: glob, source_desc: source_desc)
      end

      def gemspec_paths_in_git_revision(git_repo, revision)
        bundle.send(:gemspec_paths_in_git_revision, git_repo, revision)
      end

      def with_git_checkout(git_repo, revision, &block)
        bundle.send(:with_git_checkout, git_repo, revision, &block)
      end

      def load_gemspec_from_checkout(checkout_dir, gemspec_path)
        bundle.send(:load_gemspec_from_checkout, checkout_dir, gemspec_path)
      end

      def load_git_gemspec(git_repo, revision, gemspec_path)
        bundle.send(:load_git_gemspec, git_repo, revision, gemspec_path)
      end

      def pick_best_platform_spec(specs, local_plat)
        bundle.send(:pick_best_platform_spec, specs, local_plat)
      end

      def dependency_relevant_for_local_platform?(dep)
        bundle.send(:dependency_relevant_for_local_platform?, dep)
      end

      def gemfile_platform_matches_local?(platform)
        bundle.send(:gemfile_platform_matches_local?, platform)
      end

      def fetch_index(source, cache)
        bundle.send(:fetch_index, source, cache)
      end

      def clone_git_source(source, cache)
        bundle.send(:clone_git_source, source, cache)
      end

      # --- Phase implementations ---

      # Lockfiles can carry only the ruby variant for a gem version.
      # Re-check compact index for the same locked version and upgrade to the
      # best local platform variant when available.
      def apply_locked_platform_preferences(resolved_specs)
        preferred = preferred_platforms_for_locked_specs(resolved_specs)
        return resolved_specs if preferred.empty?

        resolved_specs.each do |spec|
          key = SpecUtils.full_name_for(spec.name, spec.version)
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

              out[SpecUtils.full_name_for(spec.name, spec.version)] = preferred
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
          ensure_git_repo_for_spec(spec, cache, fetch: true)
          return
        end
        source_uri = source.to_s

        # Path gems are not downloaded from a remote
        return if source_uri.start_with?("/") || !source_uri.start_with?("http")

        full_name = SpecUtils.full_name(spec)
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
          assemble_git_spec(entry, cache, fetch: false)
          return
        end
        return if source_uri.start_with?("/") || !source_uri.start_with?("http")

        return if Scint::Cache::Validity.cached_valid?(spec, cache)

        dest_path = cache.inbound_path(spec)
        raise InstallError, "Missing cached gem file for #{spec.name}: #{dest_path}" unless File.exist?(dest_path)

        assembling = cache.assembling_path(spec)
        tmp = "#{assembling}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        begin
          FileUtils.rm_rf(assembling)
          FileUtils.rm_rf(tmp)
          FS.mkdir_p(File.dirname(assembling))

          pkg = GemPkg::Package.new
          result = pkg.extract(dest_path, tmp)
          FS.atomic_move(tmp, assembling)
          cache_gemspec(spec, result[:gemspec], cache)

          unless Installer::ExtensionBuilder.needs_build?(spec, assembling)
            promote_assembled_gem(spec, cache, assembling, result[:gemspec], extensions: false)
          end
        ensure
          FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
        end
      end

      def git_source?(source)
        return true if source.is_a?(Source::Git)

        source_str = source.to_s
        source_str.end_with?(".git") || source_str.include?(".git/")
      end

      def path_source?(source)
        return true if source.is_a?(Source::Path)

        source_str =
          if source.respond_to?(:path)
            source.path.to_s
          else
            source.to_s
          end
        return false if source_str.empty?
        return false if source_str.start_with?("http://", "https://")
        return false if git_source?(source)

        source_str.start_with?("/", ".", "~")
      end

      def prepare_git_source(entry, cache)
        # Legacy helper used by tests/callers that expect git download+extract
        # in a single step.
        assemble_git_spec(entry, cache, fetch: true)
      end

      def ensure_git_repo_for_spec(spec, cache, fetch:)
        source = spec.source
        uri, _revision = git_source_ref(source)
        git_repo = cache.git_path(uri)

        # Serialize all git operations per repo — git uses index.lock
        # and can't handle concurrent checkouts from the same repo.
        git_mutex_for(git_repo).synchronize do
          needs_clone = !Dir.exist?(git_repo)
          if !needs_clone && fetch
            needs_clone = fetch_git_repo(git_repo) == :reclone
          end
          clone_git_repo(uri, git_repo) if needs_clone
        end

        git_repo
      end

      def assemble_git_spec(entry, cache, fetch: true)
        spec = entry.spec
        return if Scint::Cache::Validity.cached_valid?(spec, cache)

        source = spec.source
        uri, revision = git_source_ref(source)
        submodules = git_source_submodules?(source)

        git_repo = cache.git_path(uri)

        # Serialize all git operations per repo — git uses index.lock
        # and can't handle concurrent checkouts from the same repo.
        git_mutex_for(git_repo).synchronize do
          tmp_assembled = nil

          begin
            needs_clone = !Dir.exist?(git_repo)
            if !needs_clone && fetch
              needs_clone = fetch_git_repo(git_repo) == :reclone
            end
            clone_git_repo(uri, git_repo) if needs_clone

            resolved_revision = resolve_git_revision(git_repo, revision)
            assembling = cache.assembling_path(spec)
            tmp_assembled = "#{assembling}.#{Process.pid}.#{Thread.current.object_id}.tmp"
            promoter = cache_promoter(cache)

            FileUtils.rm_rf(assembling)
            FileUtils.rm_rf(tmp_assembled)
            FS.mkdir_p(File.dirname(assembling))

            promoter.validate_within_root!(cache.root, assembling, label: "assembling")
            promoter.validate_within_root!(cache.root, tmp_assembled, label: "git-assembled")

            checkout_git_revision(git_repo, resolved_revision, spec, uri, submodules: submodules)

            gem_root = resolve_git_gem_subdir(git_repo, spec)
            gem_rel = git_relative_root(git_repo, gem_root)
            dest_root = tmp_assembled
            dest_path = gem_rel.empty? ? dest_root : File.join(dest_root, gem_rel)

            promoter.validate_within_root!(cache.root, dest_path, label: "git-dest")

            FS.clone_tree(gem_root, dest_path)

            # Remove .git artifacts so assembled output is deterministic.
            Dir.glob(File.join(tmp_assembled, "**", ".git"), File::FNM_DOTMATCH).each do |path|
              FileUtils.rm_rf(path)
            end

            copy_gemspec_root_files(git_repo, gem_root, dest_root, spec)
            FS.atomic_move(tmp_assembled, assembling)

            gem_subdir = begin
              resolve_git_gem_subdir(assembling, spec)
            rescue InstallError
              assembling
            end
            gemspec = read_gemspec_from_extracted(gem_subdir, spec)
            cache_gemspec(spec, gemspec, cache) if gemspec

            unless Installer::ExtensionBuilder.needs_build?(spec, assembling)
              promote_assembled_gem(spec, cache, assembling, gemspec, extensions: false)
            end
          ensure
            FileUtils.rm_rf(tmp_assembled) if tmp_assembled && File.exist?(tmp_assembled)
          end
        end
      end

      def git_source_ref(source)
        bundle.git_source_ref(source)
      end

      def git_source_submodules?(source)
        bundle.git_source_submodules?(source)
      end

      def copy_gemspec_root_files(repo_root, gem_root, dest_root, spec)
        repo_root = File.expand_path(repo_root.to_s)
        gem_root = File.expand_path(gem_root.to_s)
        return if repo_root == gem_root

        gemspec_path = git_gemspec_path_for_root(gem_root, spec)
        return unless gemspec_path && File.exist?(gemspec_path)

        content = File.read(gemspec_path) rescue nil
        return unless content

        root_files = git_root_files_from_gemspec(content)
        root_files.each do |file|
          source = File.join(repo_root, file)
          next unless File.file?(source)

          dest = File.join(dest_root, file)
          next if File.exist?(dest)

          FS.clonefile(source, dest)
        end
      end

      def git_gemspec_path_for_root(gem_root, spec)
        if spec && spec.respond_to?(:name)
          candidate = File.join(gem_root, "#{spec.name}.gemspec")
          return candidate if File.exist?(candidate)
        end

        Dir.glob(File.join(gem_root, "*.gemspec")).first
      end

      def git_root_files_from_gemspec(content)
        files = ["RAILS_VERSION", "VERSION"]
        files.select { |file| content.include?(file) }
      end

      def git_relative_root(repo_root, gem_root)
        repo_root = File.expand_path(repo_root.to_s)
        gem_root = File.expand_path(gem_root.to_s)
        return "" if repo_root == gem_root

        if gem_root.start_with?("#{repo_root}/")
          return gem_root.delete_prefix("#{repo_root}/")
        end

        File.basename(gem_root)
      end

      def checkout_git_revision(git_repo, resolved_revision, spec, uri, submodules: false)
        _out, err, status = git_capture3(
          "-C", git_repo,
          "checkout", "-f", resolved_revision,
        )
        unless status.success?
          raise InstallError, "Git checkout failed for #{spec.name} (#{uri}@#{resolved_revision}): #{err.to_s.strip}"
        end

        return unless submodules

        _sub_out, sub_err, sub_status = git_capture3(
          "-C", git_repo,
          "-c", "protocol.file.allow=always",
          "submodule",
          "update",
          "--init",
          "--recursive",
        )
        unless sub_status.success?
          raise InstallError, "Git submodule update failed for #{spec.name} (#{uri}@#{resolved_revision}): #{sub_err.to_s.strip}"
        end
      end

      def git_mutex_for(repo_path)
        bundle.git_mutex_for(repo_path)
      end

      def clone_git_repo(uri, git_repo)
        bundle.clone_git_repo(uri, git_repo)
      end

      def fetch_git_repo(git_repo)
        bundle.fetch_git_repo(git_repo)
      end

      def resolve_git_revision(git_repo, revision)
        bundle.resolve_git_revision(git_repo, revision)
      end

      def git_capture3(*args)
        bundle.git_capture3(*args)
      end

      def compile_slots_for(worker_count)
        # Scale compile concurrency with available CPUs.
        # Most native extensions have 1-3 source files and don't benefit from
        # high make -j; running more concurrent builds is more effective.
        # Each slot gets cpu_count/slots make jobs (see adaptive_make_jobs).
        workers = [worker_count.to_i, 1].max
        override = positive_integer_env("SCINT_COMPILE_CONCURRENCY")
        return [override, workers].min if override

        cpus = Platform.cpu_count
        # Aim for 8 make-jobs per slot → slots = cpus / 8, clamped.
        slots = cpus / 8
        slots = [[slots, 2].max, workers].min
        slots
      end

      def git_slots_for(worker_count)
        workers = [worker_count.to_i, 1].max
        override = positive_integer_env("SCINT_GIT_CONCURRENCY")
        slots = override || workers
        [[slots, workers].min, 1].max
      end

      def install_task_limits(worker_count, compile_slots, git_slots = worker_count)
        # Leave headroom for compile and binstub lanes so link/download
        # throughput cannot fully starve them.
        workers = [worker_count.to_i, 1].max
        io_cpu_limit = [workers - compile_slots - 1, 1].max
        # Keep download in-flight set bounded so fail-fast exits quickly on
        # auth/source errors instead of queueing a large burst.
        download_limit = [io_cpu_limit, 8].min
        git_limit = [[git_slots.to_i, 1].max, workers].min
        {
          download: download_limit,
          extract: io_cpu_limit,
          link: io_cpu_limit,
          git_clone: git_limit,
          build_ext: compile_slots,
          binstub: 1,
        }
      end

      def positive_integer_env(key)
        raw = ENV[key]
        return nil if raw.nil? || raw.empty?

        value = Integer(raw, exception: false)
        return nil unless value
        return nil if value <= 0

        value
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
        SpecUtils.full_key(spec)
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
          begin
            if path_source?(entry.spec.source)
              resolve_path_gem_subdir(source_str, entry.spec)
            else
              resolve_git_gem_subdir(source_str, entry.spec)
            end
          rescue InstallError
            source_str
          end
        else
          cached_dir = cache.cached_path(entry.spec)
          assembling = cache.assembling_path(entry.spec)
          base = if entry.cached_path
            entry.cached_path
          elsif Scint::Cache::Validity.cached_valid?(entry.spec, cache)
            cached_dir
          elsif Dir.exist?(assembling)
            assembling
          else
            nil
          end

          if git_source?(entry.spec.source) && base && Dir.exist?(base)
            resolve_git_gem_subdir(base, entry.spec)
          elsif path_source?(entry.spec.source) && base && Dir.exist?(base)
            begin
              resolve_path_gem_subdir(base, entry.spec)
            rescue InstallError
              base
            end
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

      # For path monorepo sources, map gem name to its gemspec subdirectory.
      def resolve_path_gem_subdir(repo_root, spec)
        name = spec.name
        return repo_root if File.exist?(File.join(repo_root, "#{name}.gemspec"))

        source = spec.source
        glob = source.respond_to?(:glob) ? source.glob : Source::Path::DEFAULT_GLOB
        Dir.glob(File.join(repo_root, glob)).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end
        Dir.glob(File.join(repo_root, "**", "*.gemspec")).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end

        source_uri =
          if source.respond_to?(:path)
            source.path
          elsif source.respond_to?(:uri)
            source.uri
          else
            source.to_s
          end
        raise InstallError, "Path source #{source_uri} does not contain #{name}.gemspec (glob: #{glob.inspect})"
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

      def build_extensions(entry, cache, bundle_path, progress = nil, compile_slots: 1)
        spec = entry.spec
        extracted = extracted_path_for_entry(entry, cache)
        gemspec = load_gemspec(extracted, spec, cache)
        promote_after_build = assembling_path?(extracted, cache)

        sync_build_env_dependencies(spec, bundle_path, cache)

        prepared = PreparedGem.new(
          spec: spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )

        Installer::ExtensionBuilder.build(
          prepared,
          bundle_path,
          cache,
          compile_slots: compile_slots,
          output_tail: ->(lines) { progress&.on_build_tail(spec.name, lines) },
        )

        ruby_dir = Platform.ruby_install_dir(bundle_path)
        bundle_gem_dir = File.join(ruby_dir, "gems", SpecUtils.full_name(spec))
        if Dir.exist?(bundle_gem_dir)
          Installer::ExtensionBuilder.sync_extensions_into_gem(extracted, bundle_gem_dir)
          File.write(File.join(bundle_gem_dir, Installer::ExtensionBuilder::BUILD_MARKER), "")
        end

        return unless promote_after_build

        promote_assembled_gem(spec, cache, extracted, gemspec, extensions: true)
      rescue StandardError
        if promote_after_build && extracted && Dir.exist?(extracted)
          FileUtils.rm_rf(extracted)
        end
        raise
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

        source_ruby_dir = Platform.ruby_install_dir(bundle_path)
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
        cache_key = "#{cache.full_name(spec)}@#{extracted_path}"
        cached_value = @gemspec_cache_lock.synchronize { @gemspec_cache[cache_key] }
        return cached_value if cached_value

        cached = load_cached_gemspec(spec, cache, extracted_path)
        if cached
          @gemspec_cache_lock.synchronize { @gemspec_cache[cache_key] = cached }
          return cached
        end

        direct = read_gemspec_from_extracted(extracted_path, spec)
        if direct
          @gemspec_cache_lock.synchronize { @gemspec_cache[cache_key] = direct }
          return direct
        end

        inbound = cache.inbound_path(spec)
        return nil unless File.exist?(inbound)

        begin
          metadata = GemPkg::Package.new.read_metadata(inbound)
          cache_gemspec(spec, metadata, cache)
          @gemspec_cache_lock.synchronize { @gemspec_cache[cache_key] = metadata }
          metadata
        rescue StandardError
          nil
        end
      end

      def read_gemspec_from_extracted(extracted_dir, spec)
        return nil unless extracted_dir && Dir.exist?(extracted_dir)

        pattern = File.join(extracted_dir, "*.gemspec")
        candidates = Dir.glob(pattern)
        return nil if candidates.empty?

        load_gemspec_file(candidates.first, spec)
      end

      # Load a .gemspec file, temporarily injecting VERSION env var for gems
      # like kgio/unicorn that use `ENV["VERSION"] or abort` in their gemspec.
      def load_gemspec_file(path, spec = nil)
        version = spec.respond_to?(:version) ? spec.version.to_s : nil
        old_version = ENV["VERSION"]
        begin
          ENV["VERSION"] = version if version && !ENV["VERSION"]
          SpecUtils.load_gemspec(path, isolate: true)
        rescue SystemExit, StandardError
          nil
        ensure
          ENV["VERSION"] = old_version
        end
      end

      def bulk_prelink_gem_files(entries, cache, bundle_path)
        return if entries.length < 32

        ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
        gems_dir = File.join(ruby_dir, "gems")
        cache_abi_dir = cache.cached_abi_dir

        gem_names = []
        entries.each do |entry|
          next unless entry.action == :link || entry.action == :build_ext

          source_dir = entry.cached_path
          next unless source_dir

          full_name = cache.full_name(entry.spec)
          next unless File.basename(source_dir) == full_name
          next unless Dir.exist?(source_dir)
          next if Dir.exist?(File.join(gems_dir, full_name))

          gem_names << full_name
        end

        return if gem_names.empty?

        if ENV["SCINT_TIMING"]
          @output.puts "  [timing] prelink: #{gem_names.size} gems via linker"
        end

        FS.bulk_link_gems(cache_abi_dir, gems_dir, gem_names)
      rescue StandardError => e
        @output.puts("bulk prelink warning: #{e.message}") if ENV["SCINT_DEBUG"]
      end

      def load_cached_gemspec(spec, cache, extracted_path)
        paths = [cache.cached_spec_path(spec)]

        paths.each do |path|
          next unless File.exist?(path)

          data = File.binread(path)
          gemspec = if data.start_with?("# -*- encoding")
            # Ruby format (to_ruby output) — most reliable, preserves require_paths
            Gem::Specification.load(path)
          elsif data.start_with?("---")
            data.force_encoding("UTF-8") if data.encoding != Encoding::UTF_8
            Gem::Specification.from_yaml(data)
          else
            begin
              Marshal.load(data)
            rescue StandardError
              data.force_encoding("UTF-8") if data.encoding != Encoding::UTF_8
              Gem::Specification.from_yaml(data)
            end
          end
          return gemspec if cached_gemspec_valid?(gemspec, extracted_path)
        end

        nil
      rescue SystemExit, StandardError
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
        path = cache.cached_spec_path(spec)
        content = if gemspec.respond_to?(:to_ruby)
          gemspec.to_ruby
        else
          gemspec.to_yaml
        end
        FS.atomic_write(path, content)
      rescue StandardError
        # Non-fatal: we'll read metadata from .gem next time.
      end

      def cache_promoter(cache)
        @cache_promoter ||= Installer::Promoter.new(root: cache.root)
      end

      def assembling_path?(path, cache)
        return false if path.nil? || path.empty?

        root = File.expand_path(cache.assembling_dir)
        candidate = File.expand_path(path)
        candidate == root || candidate.start_with?("#{root}/")
      end

      def promote_assembled_gem(spec, cache, assembling_path, gemspec, extensions:)
        return unless assembling_path && Dir.exist?(assembling_path)

        cached_dir = cache.cached_path(spec)
        promoter = cache_promoter(cache)
        lock_key = "#{Platform.abi_key}-#{cache.full_name(spec)}"

        promoter.validate_within_root!(cache.root, assembling_path, label: "assembling")
        promoter.validate_within_root!(cache.root, cached_dir, label: "cached")

        begin
          result = nil
          promoter.with_staging_dir(prefix: "cached") do |staging|
            FS.clone_tree(assembling_path, staging)
            manifest = build_cached_manifest(spec, cache, staging, extensions: extensions)
            Scint::Cache::Manifest.write_dotfiles(staging, manifest)
            spec_payload = gemspec ? gemspec.to_ruby : nil
            result = promoter.promote_tree(
              staging_path: staging,
              target_path: cached_dir,
              lock_key: lock_key,
            )
            if result == :promoted
              write_cached_metadata(spec, cache, spec_payload, manifest)
            end
            FileUtils.rm_rf(assembling_path) if Dir.exist?(assembling_path)
          end
          result
        rescue StandardError
          FileUtils.rm_rf(cached_dir) if Dir.exist?(cached_dir)
          raise
        end
      end

      def write_cached_metadata(spec, cache, spec_payload, manifest)
        spec_path = cache.cached_spec_path(spec)
        manifest_path = cache.cached_manifest_path(spec)
        FS.mkdir_p(File.dirname(spec_path))

        FS.atomic_write(spec_path, spec_payload) if spec_payload
        Scint::Cache::Manifest.write(manifest_path, manifest)
      end

      def build_cached_manifest(spec, cache, gem_dir, extensions:)
        Scint::Cache::Manifest.build(
          spec: spec,
          gem_dir: gem_dir,
          abi_key: Platform.abi_key,
          source: manifest_source_for(spec),
          extensions: extensions,
        )
      end

      def manifest_source_for(spec)
        source = spec.source
        if source.is_a?(Source::Git)
          {
            "type" => "git",
            "uri" => source.uri.to_s,
            "revision" => source.revision || source.ref || source.branch || source.tag,
          }.compact
        elsif source.is_a?(Source::Path)
          {
            "type" => "path",
            "path" => File.expand_path(source.path.to_s),
            "uri" => source.path.to_s,
          }
        else
          source_str = source.to_s
          if source_str.start_with?("http://", "https://")
            { "type" => "rubygems", "uri" => source_str }
          elsif path_source?(source)
            { "type" => "path", "path" => File.expand_path(source_str), "uri" => source_str }
          else
            { "type" => "rubygems", "uri" => source_str }
          end
        end
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
        gemfile.dependencies
          .select { |dep| lockfile_dependency_direct?(dep) }
          .map do |dep|
            locked_dep = locked[dep.name]
            {
              name: dep.name,
              version_reqs: dep.version_reqs,
              pinned: !!(locked_dep && locked_dep[:pinned]),
            }
          end
      end

      def lockfile_dependency_direct?(dep)
        opts = dep.source_options || {}
        return true unless opts[:gemspec_generated]

        opts[:gemspec_primary] != false
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
        SpecUtils.full_name_for(spec[:name], spec[:version], spec[:platform] || "ruby")
      end

      def write_runtime_config(resolved, bundle_path)
        ruby_dir = Platform.ruby_install_dir(bundle_path)

        data = {}
        resolved.each do |spec|
          full = SpecUtils.full_name(spec)
          gem_dir = File.join(ruby_dir, "gems", full)
          spec_file = File.join(ruby_dir, "specifications", "#{full}.gemspec")
          require_paths = read_require_paths(spec_file)
          load_paths = require_paths
            .map { |rp| expand_require_path(gem_dir, rp) }
            .select { |path| Dir.exist?(path) }

          default_lib = File.join(gem_dir, "lib")
          load_paths << default_lib if load_paths.empty? && Dir.exist?(default_lib)
          load_paths.uniq!

          # Add ext load path if extensions exist
          ext_dir = File.join(ruby_dir, "extensions",
                              Platform.gem_arch, Platform.extension_api_version, full)
          load_paths << ext_dir if Dir.exist?(ext_dir)

          if load_paths.empty?
            source_paths = runtime_source_load_paths(spec)
            load_paths.concat(source_paths)
            load_paths.uniq!
          end

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

        gemspec = SpecUtils.load_gemspec(spec_file)
        paths = Array(gemspec&.require_paths).reject(&:empty?)
        paths.empty? ? ["lib"] : paths
      rescue SystemExit, StandardError
        ["lib"]
      end

      def expand_require_path(gem_dir, require_path)
        value = require_path.to_s
        return value if Pathname.new(value).absolute?

        File.join(gem_dir, value)
      rescue StandardError
        File.join(gem_dir, require_path.to_s)
      end

      def runtime_source_load_paths(spec)
        source_root = spec.source.to_s
        return [] unless source_root.start_with?("/") && Dir.exist?(source_root)

        source_dir = begin
          resolve_git_gem_subdir(source_root, spec)
        rescue InstallError
          source_root
        end

        gemspec_file = File.join(source_dir, "#{spec.name}.gemspec")
        require_paths = read_require_paths(gemspec_file)
        paths = require_paths
          .map { |rp| expand_require_path(source_dir, rp) }
          .select { |path| Dir.exist?(path) }

        default_lib = File.join(source_dir, "lib")
        paths << default_lib if paths.empty? && Dir.exist?(default_lib)
        paths.uniq
      rescue StandardError
        []
      end

      def spec_full_name(spec)
        SpecUtils.full_name(spec)
      end

      def elapsed_ms_since(start_time)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        (elapsed * 1000).round
      end

      def force_purge_artifacts(resolved, bundle_path, cache)
        ruby_dir = Platform.ruby_install_dir(bundle_path)
        ext_root = File.join(ruby_dir, "extensions", Platform.gem_arch, Platform.extension_api_version)

        resolved.each do |spec|
          full = cache.full_name(spec)

          # Global cache artifacts.
          FileUtils.rm_f(cache.inbound_path(spec))
          FileUtils.rm_rf(cache.assembling_path(spec))
          FileUtils.rm_rf(cache.cached_path(spec))
          FileUtils.rm_f(cache.cached_spec_path(spec))
          FileUtils.rm_f(cache.cached_manifest_path(spec))
          FileUtils.rm_f(cache.spec_cache_path(spec))
          FileUtils.rm_rf(cache.extracted_path(spec))
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
          @output.puts "    headers:"
          headers.sort.each do |key, value|
            @output.puts "      #{key}: #{value}"
          end
        end

        return if body.empty?

        @output.puts "    body:"
        body.each_line do |line|
          @output.puts "      #{line.rstrip}"
        end
      end

      def warn_missing_bundle_gitignore_entry
        path = ".gitignore"
        return unless File.file?(path)
        return if gitignore_has_bundle_entry?(path)

        @output.puts "#{YELLOW}Warning: .gitignore exists but does not ignore .bundle (add `.bundle/`).#{RESET}"
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
          when "--without"
            @without_groups = @argv[i + 1]&.split(/[\s:,]+/)&.map(&:to_sym) || []
            i += 2
          when "--with"
            @with_groups = @argv[i + 1]&.split(/[\s:,]+/)&.map(&:to_sym) || []
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

        # Also read BUNDLE_WITHOUT / BUNDLE_WITH env vars (Bundler compat)
        if !@without_groups && ENV["BUNDLE_WITHOUT"]
          @without_groups = ENV["BUNDLE_WITHOUT"].split(/[\s:,]+/).map(&:to_sym)
        end
        if !@with_groups && ENV["BUNDLE_WITH"]
          @with_groups = ENV["BUNDLE_WITH"].split(/[\s:,]+/).map(&:to_sym)
        end

        # Read from .bundle/config if present
        load_bundle_config_groups if !@without_groups && !@with_groups
      end

      def load_bundle_config_groups
        config_path = File.join(".bundle", "config")
        return unless File.exist?(config_path)

        config = YAML.safe_load(File.read(config_path)) rescue nil
        return unless config.is_a?(Hash)

        if config["BUNDLE_WITHOUT"] && !@without_groups
          @without_groups = config["BUNDLE_WITHOUT"].to_s.split(/[\s:]+/).map(&:to_sym)
        end
        if config["BUNDLE_WITH"] && !@with_groups
          @with_groups = config["BUNDLE_WITH"].to_s.split(/[\s:]+/).map(&:to_sym)
        end
      end
    end
  end
end
