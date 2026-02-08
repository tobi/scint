# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "layout"
require_relative "manifest"
require_relative "validity"
require_relative "../errors"
require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../fs"
require_relative "../platform"
require_relative "../worker_pool"
require_relative "../installer/extension_builder"
require_relative "../installer/promoter"
require_relative "../source/git"
require_relative "../source/path"

module Scint
  module Cache
    class Prewarm
      Task = Struct.new(:spec, :download, :extract, keyword_init: true)

      def initialize(cache_layout: Layout.new, jobs: nil, credentials: nil, force: false,
                     downloader_factory: nil)
        @cache = cache_layout
        @jobs = [[jobs || (Platform.cpu_count * 2), 1].max, 50].min
        @credentials = credentials
        @force = force
        @downloader_factory = downloader_factory || lambda { |size, creds|
          Downloader::Pool.new(size: size, credentials: creds)
        }
        @git_mutexes = {}
        @git_mutexes_lock = Thread::Mutex.new
      end

      # Returns summary hash:
      # { warmed:, skipped:, ignored:, failed:, failures: [] }
      def run(specs)
        failures = []
        ignored = 0
        skipped = 0

        gem_tasks = []
        git_tasks = []

        specs.each do |spec|
          if git_source?(spec.source)
            git_tasks << task_for_git(spec)
          elsif rubygems_source?(spec.source)
            gem_tasks << task_for(spec)
          else
            ignored += 1
          end
        end

        all_tasks = gem_tasks + git_tasks

        all_tasks.each do |task|
          next unless @force
          purge_artifacts(task.spec)
          task.download = true
          task.extract = true
        end

        all_tasks.each do |task|
          skipped += 1 if !task.download && !task.extract
        end

        work_gem_tasks = gem_tasks.select { |t| t.download || t.extract }
        work_git_tasks = git_tasks.select { |t| t.download || t.extract }

        return result_hash(0, skipped, ignored, failures) if work_gem_tasks.empty? && work_git_tasks.empty?

        # Phase 1: Fetch — download .gem files + clone/fetch git repos
        download_errors = download_tasks(work_gem_tasks.select(&:download))
        failures.concat(download_errors)

        git_fetch_errors = git_fetch_tasks(work_git_tasks.select(&:download))
        failures.concat(git_fetch_errors)

        # Phase 2: Extract — expand .gem payloads + checkout/assemble git trees
        remaining_gems = work_gem_tasks.reject { |t| failures.any? { |f| f[:spec] == t.spec } }
        extract_errors = extract_tasks(remaining_gems.select(&:extract))
        failures.concat(extract_errors)

        remaining_gits = work_git_tasks.reject { |t| failures.any? { |f| f[:spec] == t.spec } }
        git_assemble_errors = git_assemble_tasks(remaining_gits.select(&:extract))
        failures.concat(git_assemble_errors)

        total_work = work_gem_tasks.size + work_git_tasks.size
        result_hash(total_work - failures.size, skipped, ignored, failures)
      end

      private

      # -- Task classification -------------------------------------------------

      def git_source?(source)
        source.is_a?(Source::Git)
      end

      def rubygems_source?(source)
        source_str = source.to_s
        source_str.start_with?("http://", "https://")
      end

      def task_for(spec)
        inbound = @cache.inbound_path(spec)
        cached_valid = Cache::Validity.cached_valid?(spec, @cache)

        Task.new(
          spec: spec,
          download: !File.exist?(inbound),
          extract: !cached_valid,
        )
      end

      def task_for_git(spec)
        cached_valid = Cache::Validity.cached_valid?(spec, @cache)
        return Task.new(spec: spec, download: false, extract: false) if cached_valid

        uri = spec.source.uri.to_s
        bare_repo = @cache.git_path(uri)

        Task.new(
          spec: spec,
          download: !Dir.exist?(bare_repo),
          # Git gems always need assembly if not cached, even when the bare
          # repo is already present (the checkout may be stale/missing).
          extract: true,
        )
      end

      # -- Rubygems download ---------------------------------------------------

      def download_tasks(tasks)
        return [] if tasks.empty?

        downloader = @downloader_factory.call(@jobs, @credentials)
        items = tasks.map do |task|
          spec = task.spec
          {
            spec: spec,
            uri: download_uri_for(spec),
            dest: @cache.inbound_path(spec),
            checksum: spec.respond_to?(:checksum) ? spec.checksum : nil,
          }
        end

        results = downloader.download_batch(items)
        failures = results.select { |r| r[:error] }.map do |r|
          { spec: r[:spec], error: r[:error] }
        end
        failures
      ensure
        downloader&.close
      end

      # -- Git fetch (clone/fetch bare repos) ----------------------------------

      def git_fetch_tasks(tasks)
        return [] if tasks.empty?

        failures = []
        mutex = Thread::Mutex.new
        done = Thread::Queue.new

        # Deduplicate by URI so we only clone/fetch each repo once.
        by_uri = {}
        tasks.each do |task|
          uri = task.spec.source.uri.to_s
          by_uri[uri] ||= []
          by_uri[uri] << task
        end

        pool = WorkerPool.new([@jobs, by_uri.size].min, name: "prewarm-git-fetch")
        pool.start do |uri|
          bare_repo = @cache.git_path(uri)
          git_mutex_for(bare_repo).synchronize do
            if Dir.exist?(bare_repo)
              fetch_git_repo(bare_repo)
            else
              clone_git_repo(uri, bare_repo)
            end
          end
          true
        end

        by_uri.each do |uri, uri_tasks|
          pool.enqueue(uri) do |job|
            mutex.synchronize do
              if job[:state] == :failed
                uri_tasks.each do |task|
                  failures << { spec: task.spec, error: job[:error] }
                end
              end
            end
            done.push(true)
          end
        end

        by_uri.size.times { done.pop }
        pool.stop

        failures
      end

      # -- Rubygems extract ----------------------------------------------------

      def extract_tasks(tasks)
        return [] if tasks.empty?

        failures = []
        mutex = Thread::Mutex.new
        done = Thread::Queue.new

        pool = WorkerPool.new(@jobs, name: "prewarm-extract")
        pool.start do |task|
          spec = task.spec
          inbound = @cache.inbound_path(spec)

          unless File.exist?(inbound)
            raise CacheError, "Missing downloaded gem for #{spec.name}: #{inbound}"
          end

          assembling = @cache.assembling_path(spec)
          tmp = "#{assembling}.#{Process.pid}.#{Thread.current.object_id}.tmp"

          gemspec = nil
          if task.extract
            FileUtils.rm_rf(assembling)
            FileUtils.rm_rf(tmp)
            FS.mkdir_p(File.dirname(assembling))

            result = GemPkg::Package.new.extract(inbound, tmp)
            gemspec = result[:gemspec]
            FS.atomic_move(tmp, assembling)
          end

          if gemspec
            promote_assembled(spec, assembling, gemspec)
          end

          true
        ensure
          FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
        end

        tasks.each do |task|
          pool.enqueue(task) do |job|
            mutex.synchronize do
              if job[:state] == :failed
                failures << { spec: job[:payload].spec, error: job[:error] }
              end
            end
            done.push(true)
          end
        end

        tasks.size.times { done.pop }
        pool.stop

        failures
      end

      # -- Git assemble (checkout + promote) -----------------------------------

      def git_assemble_tasks(tasks)
        return [] if tasks.empty?

        failures = []
        mutex = Thread::Mutex.new
        done = Thread::Queue.new

        pool = WorkerPool.new(@jobs, name: "prewarm-git-assemble")
        pool.start do |task|
          assemble_git_spec(task.spec)
          true
        end

        tasks.each do |task|
          pool.enqueue(task) do |job|
            mutex.synchronize do
              if job[:state] == :failed
                failures << { spec: job[:payload].spec, error: job[:error] }
              end
            end
            done.push(true)
          end
        end

        tasks.size.times { done.pop }
        pool.stop

        failures
      end

      # Checkout a git source into the assembling cache and promote to cached.
      # This mirrors CLI::Install#assemble_git_spec but without install/link.
      def assemble_git_spec(spec)
        return if Cache::Validity.cached_valid?(spec, @cache)

        source = spec.source
        uri = source.uri.to_s
        revision = source.revision || source.ref || source.branch || source.tag || "HEAD"
        submodules = source.respond_to?(:submodules) && !!source.submodules

        bare_repo = @cache.git_path(uri)
        raise CacheError, "Missing git repo for #{spec.name}: #{bare_repo}" unless Dir.exist?(bare_repo)

        git_mutex_for(bare_repo).synchronize do
          tmp_checkout = nil
          tmp_assembled = nil

          begin
            resolved_revision = resolve_git_revision(bare_repo, revision)
            assembling = @cache.assembling_path(spec)
            tmp_checkout = "#{assembling}.checkout.#{Process.pid}.#{Thread.current.object_id}.tmp"
            tmp_assembled = "#{assembling}.#{Process.pid}.#{Thread.current.object_id}.tmp"
            promoter = Installer::Promoter.new(root: @cache.root)

            FileUtils.rm_rf(assembling)
            FileUtils.rm_rf(tmp_checkout)
            FileUtils.rm_rf(tmp_assembled)
            FS.mkdir_p(File.dirname(assembling))

            if submodules
              checkout_git_tree_with_submodules(bare_repo, tmp_checkout, resolved_revision, spec, uri)
            else
              checkout_git_tree(bare_repo, tmp_checkout, resolved_revision, spec, uri)
            end

            # Strip .git internals for deterministic cache content
            Dir.glob(File.join(tmp_checkout, "**", ".git"), File::FNM_DOTMATCH).each do |path|
              FileUtils.rm_rf(path)
            end

            gem_root = resolve_git_gem_subdir(tmp_checkout, spec)
            gem_rel = git_relative_root(tmp_checkout, gem_root)
            dest_path = gem_rel.empty? ? tmp_assembled : File.join(tmp_assembled, gem_rel)

            FS.clone_tree(gem_root, dest_path)
            copy_gemspec_root_files(tmp_checkout, gem_root, tmp_assembled, spec)
            FS.atomic_move(tmp_assembled, assembling)

            gem_subdir = begin
              resolve_git_gem_subdir(assembling, spec)
            rescue InstallError
              assembling
            end
            gemspec = read_gemspec_from_dir(gem_subdir, spec)

            unless Installer::ExtensionBuilder.needs_build?(spec, assembling)
              promote_assembled(spec, assembling, gemspec)
            end
          ensure
            FileUtils.rm_rf(tmp_checkout) if tmp_checkout && File.exist?(tmp_checkout)
            FileUtils.rm_rf(tmp_assembled) if tmp_assembled && File.exist?(tmp_assembled)
          end
        end
      end

      # -- Promote / metadata --------------------------------------------------

      def promote_assembled(spec, assembling, gemspec)
        return unless assembling && Dir.exist?(assembling)

        cached_dir = @cache.cached_path(spec)
        promoter = Installer::Promoter.new(root: @cache.root)
        lock_key = "#{Platform.abi_key}-#{@cache.full_name(spec)}"
        extensions = Installer::ExtensionBuilder.needs_build?(spec, assembling)

        promoter.with_staging_dir(prefix: "cached") do |staging|
          FS.clone_tree(assembling, staging)
          manifest = Cache::Manifest.build(
            spec: spec,
            gem_dir: staging,
            abi_key: Platform.abi_key,
            source: manifest_source_for(spec),
            extensions: extensions,
          )
          spec_payload = gemspec ? Marshal.dump(gemspec) : nil
          result = promoter.promote_tree(
            staging_path: staging,
            target_path: cached_dir,
            lock_key: lock_key,
          )
          write_cached_metadata(spec, spec_payload, manifest) if result == :promoted
        end

        FileUtils.rm_rf(assembling)
      end

      def manifest_source_for(spec)
        source = spec.source
        if source.is_a?(Source::Git)
          {
            "type" => "git",
            "uri" => source.uri.to_s,
            "revision" => source.revision || source.ref || source.branch || source.tag,
          }.compact
        else
          { "type" => "rubygems", "uri" => source.to_s }
        end
      end

      def write_cached_metadata(spec, spec_payload, manifest)
        spec_path = @cache.cached_spec_path(spec)
        manifest_path = @cache.cached_manifest_path(spec)
        FS.mkdir_p(File.dirname(spec_path))

        FS.atomic_write(spec_path, spec_payload) if spec_payload
        Cache::Manifest.write(manifest_path, manifest)
      end

      # -- Git helpers (same logic as CLI::Install) ----------------------------

      def clone_git_repo(uri, bare_repo)
        FS.mkdir_p(File.dirname(bare_repo))
        _out, err, status = git_capture3("clone", "--bare", uri.to_s, bare_repo)
        unless status.success?
          raise CacheError, "Git clone failed for #{uri}: #{err.to_s.strip}"
        end
      end

      def fetch_git_repo(bare_repo)
        _out, err, status = git_capture3(
          "--git-dir", bare_repo,
          "fetch", "--prune", "origin",
          "+refs/heads/*:refs/heads/*",
          "+refs/tags/*:refs/tags/*",
        )
        unless status.success?
          raise CacheError, "Git fetch failed for #{bare_repo}: #{err.to_s.strip}"
        end
      end

      def resolve_git_revision(bare_repo, revision)
        out, err, status = git_capture3("--git-dir", bare_repo, "rev-parse", "#{revision}^{commit}")
        unless status.success?
          raise CacheError, "Unable to resolve git revision #{revision.inspect} in #{bare_repo}: #{err.to_s.strip}"
        end
        out.strip
      end

      def checkout_git_tree(bare_repo, destination, resolved_revision, spec, uri)
        FileUtils.mkdir_p(destination)
        _out, err, status = git_capture3(
          "--git-dir", bare_repo,
          "--work-tree", destination,
          "checkout", "-f", resolved_revision, "--", ".",
        )
        unless status.success?
          raise CacheError, "Git checkout failed for #{spec.name} (#{uri}@#{resolved_revision}): #{err.to_s.strip}"
        end
      end

      def checkout_git_tree_with_submodules(bare_repo, destination, resolved_revision, spec, uri)
        worktree = "#{destination}.worktree"
        FileUtils.rm_rf(worktree)

        _out, err, status = git_capture3(
          "--git-dir", bare_repo,
          "worktree", "add", "--detach", "--force", worktree, resolved_revision,
        )
        unless status.success?
          raise CacheError, "Git worktree checkout failed for #{spec.name} (#{uri}@#{resolved_revision}): #{err.to_s.strip}"
        end

        begin
          _sub_out, sub_err, sub_status = git_capture3(
            "-C", worktree,
            "-c", "protocol.file.allow=always",
            "submodule", "update", "--init", "--recursive",
          )
          unless sub_status.success?
            raise CacheError, "Git submodule update failed for #{spec.name} (#{uri}@#{resolved_revision}): #{sub_err.to_s.strip}"
          end

          FS.clone_tree(worktree, destination)

          Dir.glob(File.join(destination, "**", ".git"), File::FNM_DOTMATCH).each do |path|
            FileUtils.rm_rf(path)
          end
        ensure
          git_capture3("--git-dir", bare_repo, "worktree", "remove", "--force", worktree)
          FileUtils.rm_rf(worktree)
        end
      end

      def resolve_git_gem_subdir(repo_root, spec)
        name = spec.name
        return repo_root if File.exist?(File.join(repo_root, "#{name}.gemspec"))

        source = spec.source
        glob = source.respond_to?(:glob) ? source.glob : Source::Git::DEFAULT_GLOB
        Dir.glob(File.join(repo_root, glob)).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end
        Dir.glob(File.join(repo_root, "**", "*.gemspec")).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == name
        end

        raise CacheError,
              "Git source #{source.uri} does not contain #{name}.gemspec (glob: #{glob.inspect})"
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

      def copy_gemspec_root_files(repo_root, gem_root, dest_root, spec)
        repo_root = File.expand_path(repo_root.to_s)
        gem_root = File.expand_path(gem_root.to_s)
        return if repo_root == gem_root

        gemspec_path = Dir.glob(File.join(gem_root, "*.gemspec")).first
        gemspec_path ||= File.join(gem_root, "#{spec.name}.gemspec")
        return unless File.exist?(gemspec_path)

        content = File.read(gemspec_path) rescue nil
        return unless content

        %w[RAILS_VERSION VERSION].each do |file|
          next unless content.include?(file)
          source = File.join(repo_root, file)
          next unless File.file?(source)
          dest = File.join(dest_root, file)
          next if File.exist?(dest)
          FS.clonefile(source, dest)
        end
      end

      def read_gemspec_from_dir(dir, spec)
        return nil unless dir && Dir.exist?(dir)

        candidates = Dir.glob(File.join(dir, "*.gemspec"))
        return nil if candidates.empty?

        version = spec.respond_to?(:version) ? spec.version.to_s : nil
        old_version = ENV["VERSION"]
        begin
          ENV["VERSION"] = version if version && !ENV["VERSION"]
          Gem::Specification.load(candidates.first)
        rescue SystemExit, StandardError
          nil
        ensure
          ENV["VERSION"] = old_version
        end
      end

      def git_mutex_for(repo_path)
        @git_mutexes_lock.synchronize do
          @git_mutexes[repo_path] ||= Thread::Mutex.new
        end
      end

      def git_capture3(*args)
        Open3.capture3("git", "-c", "core.fsmonitor=false", *args)
      end

      # -- Rubygems helpers ----------------------------------------------------

      def download_uri_for(spec)
        source = spec.source.to_s.chomp("/")
        "#{source}/gems/#{@cache.full_name(spec)}.gem"
      end

      def purge_artifacts(spec)
        FileUtils.rm_f(@cache.inbound_path(spec))
        FileUtils.rm_rf(@cache.assembling_path(spec))
        FileUtils.rm_rf(@cache.cached_path(spec))
        FileUtils.rm_f(@cache.cached_spec_path(spec))
        FileUtils.rm_f(@cache.cached_manifest_path(spec))
        FileUtils.rm_f(@cache.spec_cache_path(spec))
        FileUtils.rm_rf(@cache.extracted_path(spec))
        FileUtils.rm_rf(@cache.ext_path(spec))
      end

      def result_hash(warmed, skipped, ignored, failures)
        {
          warmed: warmed,
          skipped: skipped,
          ignored: ignored,
          failed: failures.size,
          failures: failures,
        }
      end

      # Legacy compatibility — old callers may still check this.
      def prewarmable?(spec)
        rubygems_source?(spec.source) || git_source?(spec.source)
      end
    end
  end
end
