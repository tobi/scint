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

module Bundler2
  module CLI
    class Install
      RUNTIME_LOCK = "bundler2.lock.marshal"

      def initialize(argv = [])
        @argv = argv
        @jobs = nil
        @path = nil
        @verbose = false
        parse_options
      end

      def run
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        cache = Cache::Layout.new
        bundle_path = @path || ENV["BUNDLER_PATH"] || ".bundle"
        bundle_path = File.expand_path(bundle_path)
        worker_count = @jobs || [Platform.cpu_count * 2, 50].min

        # 1. Start the scheduler with 1 worker — scale up dynamically
        scheduler = Scheduler.new(max_workers: worker_count)
        scheduler.start

        begin
          # 2. Parse Gemfile
          gemfile = Bundler2::Gemfile::Parser.parse("Gemfile")

          # Scale workers based on dependency count
          dep_count = gemfile.dependencies.size
          scheduler.scale_workers(dep_count)

          # 3. Enqueue index fetches for all sources immediately
          gemfile.sources.each do |source|
            scheduler.enqueue(:fetch_index, source.to_s,
                              -> { fetch_index(source, cache) })
          end

          # 4. Parse lockfile if it exists
          lockfile = nil
          if File.exist?("Gemfile.lock")
            lockfile = Bundler2::Lockfile::Parser.parse("Gemfile.lock")
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

          # 7. Plan: diff resolved vs installed
          plan = Installer::Planner.plan(resolved, bundle_path, cache)

          skipped = plan.count { |e| e.action == :skip }
          to_install = plan.reject { |e| e.action == :skip }

          # Scale up for download/install phase based on actual work count
          scheduler.scale_workers(to_install.size)

          if to_install.empty?
            $stdout.puts "Bundle complete! #{skipped} gems already installed."
            return 0
          end

          # 8. Enqueue downloads — each one chains into extract → link
          plan.each do |entry|
            case entry.action
            when :download
              download_id = scheduler.enqueue(
                :download, entry.spec.name,
                -> { download_gem(entry, cache) },
                follow_up: ->(job) { enqueue_post_download(scheduler, entry, cache, bundle_path) }
              )
            when :link
              scheduler.enqueue(:link, entry.spec.name,
                                -> { link_gem(entry, cache, bundle_path) })
            when :build_ext
              scheduler.enqueue(:build_ext, entry.spec.name,
                                -> { build_and_link(entry, cache, bundle_path) })
            end
          end

          # 9. Wait for everything
          scheduler.wait_all

          errors = scheduler.errors.dup
          stats = scheduler.stats
          if errors.any?
            $stderr.puts "Some gems failed to install:"
            errors.each do |err|
              $stderr.puts "  #{err[:name]}: #{err[:error].message}"
            end
          elsif stats[:failed] > 0
            $stderr.puts "Warning: #{stats[:failed]} jobs failed but no error details captured"
          end

          # 10. Write lockfile + runtime config
          write_lockfile(resolved, gemfile)
          write_runtime_config(resolved, bundle_path)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          installed_count = to_install.size
          $stdout.puts "Bundle complete! #{installed_count} gems installed, #{skipped} already up to date. (#{elapsed.round(2)}s)"

          (errors.any? || stats[:failed] > 0) ? 1 : 0
        ensure
          scheduler.shutdown
        end
      end

      private

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
          clients[uri] = Index::Client.new(uri)
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
            prev_stderr = $stderr.dup
            $stderr.reopen(File::NULL)
            spec = Gem::Specification.load(gs)
            return spec if spec
          rescue StandardError
            nil
          ensure
            $stderr.reopen(prev_stderr)
            prev_stderr.close
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
          ResolvedSpec.new(
            name: ls[:name],
            version: ls[:version],
            platform: ls[:platform],
            dependencies: ls[:dependencies],
            source: ls[:source],
            has_extensions: false,
            remote_uri: nil,
            checksum: ls[:checksum],
          )
        end
      end

      def download_gem(entry, cache)
        spec = entry.spec
        source_uri = spec.source.to_s

        # Path/git gems are not downloaded from a remote
        return if source_uri.start_with?("/") || !source_uri.start_with?("http")

        full_name = spec_full_name(spec)
        gem_filename = "#{full_name}.gem"
        source_uri = source_uri.chomp("/")
        download_uri = "#{source_uri}/gems/#{gem_filename}"
        dest_path = cache.inbound_path(spec)

        FS.mkdir_p(File.dirname(dest_path))

        unless File.exist?(dest_path)
          pool = Downloader::Pool.new(size: 1)
          pool.download(download_uri, dest_path)
          pool.close
        end

        # Extract
        extracted = cache.extracted_path(spec)
        unless Dir.exist?(extracted)
          FS.mkdir_p(extracted)
          pkg = GemPkg::Package.new
          pkg.extract(dest_path, extracted)
        end
      end

      def enqueue_post_download(scheduler, entry, cache, bundle_path)
        # Check if gem has native extensions by looking at the extracted directory
        extracted = cache.extracted_path(entry.spec)
        needs_ext = entry.spec.respond_to?(:has_extensions) && entry.spec.has_extensions
        needs_ext ||= has_ext_dir?(extracted)

        if needs_ext
          scheduler.enqueue(:build_ext, entry.spec.name,
                            -> { build_and_link(entry, cache, bundle_path) })
        else
          scheduler.enqueue(:link, entry.spec.name,
                            -> { link_gem(entry, cache, bundle_path) })
        end
      end

      def has_ext_dir?(extracted_path)
        Dir.exist?(File.join(extracted_path, "ext"))
      end

      def link_gem(entry, cache, bundle_path)
        spec = entry.spec
        source_str = spec.source.to_s

        # For path gems, link directly from the source path
        if source_str.start_with?("/") && Dir.exist?(source_str)
          extracted = source_str
        else
          extracted = entry.cached_path || cache.extracted_path(spec)
        end

        gemspec = load_gemspec(extracted, spec)

        prepared = PreparedGem.new(
          spec: spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )
        Installer::Linker.link(prepared, bundle_path)
      end

      def build_and_link(entry, cache, bundle_path)
        extracted = entry.cached_path || cache.extracted_path(entry.spec)
        gemspec = load_gemspec(extracted, entry.spec)

        prepared = PreparedGem.new(
          spec: entry.spec,
          extracted_path: extracted,
          gemspec: gemspec,
          from_cache: true,
        )

        Installer::ExtensionBuilder.build(prepared, bundle_path, cache)
        Installer::Linker.link(prepared, bundle_path)
      end

      def load_gemspec(extracted_path, spec)
        pattern = File.join(extracted_path, "*.gemspec")
        gemspec_files = Dir.glob(pattern)

        if gemspec_files.any?
          begin
            prev_stderr = $stderr.dup
            $stderr.reopen(File::NULL)
            return Gem::Specification.load(gemspec_files.first)
          rescue StandardError
            nil
          ensure
            $stderr.reopen(prev_stderr)
            prev_stderr.close
          end
        end
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
          bundler_version: Bundler2::VERSION,
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
          load_paths = [File.join(gem_dir, "lib")]

          # Add ext load path if extensions exist
          ext_dir = File.join(ruby_dir, "extensions",
                              Platform.arch, Platform.ruby_version, full)
          load_paths << ext_dir if Dir.exist?(ext_dir)

          data[spec.name] = {
            version: spec.version.to_s,
            load_paths: load_paths,
          }
        end

        lock_path = File.join(bundle_path, RUNTIME_LOCK)
        FS.atomic_write(lock_path, Marshal.dump(data))
      end

      def spec_full_name(spec)
        base = "#{spec.name}-#{spec.version}"
        plat = spec.respond_to?(:platform) ? spec.platform : nil
        (plat.nil? || plat.to_s == "ruby" || plat.to_s.empty?) ? base : "#{base}-#{plat}"
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
          else
            i += 1
          end
        end
      end
    end
  end
end
