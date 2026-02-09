# frozen_string_literal: true

require_relative "errors"
require_relative "fs"
require_relative "platform"
require_relative "spec_utils"
require_relative "gemfile/dependency"
require_relative "gemfile/parser"
require_relative "lockfile/parser"
require_relative "source/base"
require_relative "source/rubygems"
require_relative "source/git"
require_relative "source/path"
require_relative "index/parser"
require_relative "index/cache"
require_relative "index/client"
require_relative "cache/layout"
require_relative "cache/manifest"
require_relative "cache/metadata_store"
require_relative "cache/validity"
require_relative "installer/planner"
require_relative "vendor/pub_grub"
require_relative "resolver/provider"
require_relative "resolver/resolver"
require_relative "credentials"
require "open3"
require "set"
require "pathname"

module Scint
  class Bundle
    attr_reader :root

    def initialize(root = ".", without: nil, with: nil, credentials: nil)
      @root = File.expand_path(root)
      @without_groups = Array(without).map(&:to_sym) if without
      @with_groups = Array(with).map(&:to_sym) if with
      @credentials = credentials
      @gemspec_cache = {}
      @gemspec_cache_lock = Thread::Mutex.new
      @gemfile_result = nil
      @lockfile_result = nil
      @cache_layout = nil
    end

    # -- Lazy accessors -------------------------------------------------------

    def gemfile
      @gemfile_result ||= Scint::Gemfile::Parser.parse(gemfile_path)
    end

    def lockfile
      return @lockfile_result if defined?(@lockfile_parsed)

      @lockfile_parsed = true
      @lockfile_result = if File.exist?(lockfile_path)
        Scint::Lockfile::Parser.parse(lockfile_path)
      end
    end

    def cache
      @cache_layout ||= Scint::Cache::Layout.new
    end

    # -- Core pipeline --------------------------------------------------------

    def resolve(fetch_indexes: true)
      gf = gemfile
      lf = lockfile

      register_credentials(gf, lf)

      if fetch_indexes
        fetch_all_indexes(gf, cache)
        clone_all_git_sources(gf, cache)
      end

      resolved = run_resolve(gf, lf, cache)
      resolved = dedupe_resolved_specs(adjust_meta_gems(resolved))
      filter_excluded_gems(resolved, gf)
    end

    def plan(bundle_path: ".bundle")
      resolved = resolve
      bundle_path = File.expand_path(bundle_path, @root)
      Installer::Planner.plan(resolved, bundle_path, cache)
    end

    # -- Group filtering (public for CLI) -------------------------------------

    def excluded_gem_names(gf = gemfile, resolved: nil)
      excluded_groups = compute_excluded_groups(gf)
      return Set.new if excluded_groups.empty?

      gem_groups = Hash.new { |h, k| h[k] = Set.new }
      gf.dependencies.each do |dep|
        dep.groups.each { |g| gem_groups[dep.name] << g }
      end

      directly_excluded = Set.new
      gem_groups.each do |name, groups|
        directly_excluded << name if groups.subset?(excluded_groups)
      end

      if resolved && directly_excluded.any?
        exclude_transitive_deps(directly_excluded, resolved, gem_groups)
      else
        directly_excluded
      end
    end

    # -- Git shell helpers (public for CLI delegation) ------------------------

    def clone_git_repo(uri, git_repo)
      FS.mkdir_p(File.dirname(git_repo))
      _out, err, status = git_capture3("clone", uri.to_s, git_repo)
      unless status.success?
        raise InstallError, "Git clone failed for #{uri}: #{err.to_s.strip}"
      end
    end

    def fetch_git_repo(git_repo)
      if Dir.exist?(git_repo) && !File.exist?(File.join(git_repo, ".git"))
        FileUtils.rm_rf(git_repo)
        return :reclone
      end

      _out, err, status = git_capture3(
        "-C", git_repo,
        "fetch",
        "--prune",
        "--force",
        "origin",
      )
      unless status.success?
        raise InstallError, "Git fetch failed for #{git_repo}: #{err.to_s.strip}"
      end
    end

    def resolve_git_revision(git_repo, revision)
      out, _err, status = git_capture3("-C", git_repo, "rev-parse", "origin/#{revision}^{commit}")
      return out.strip if status.success?

      out, err, status = git_capture3("-C", git_repo, "rev-parse", "#{revision}^{commit}")
      unless status.success?
        raise InstallError, "Unable to resolve git revision #{revision.inspect} in #{git_repo}: #{err.to_s.strip}"
      end
      out.strip
    end

    def git_capture3(*args)
      Open3.capture3("git", "-c", "core.fsmonitor=false", *args)
    end

    def git_source_ref(source)
      if source.is_a?(Source::Git)
        revision = source.revision || source.ref || source.branch || source.tag || "HEAD"
        return [source.uri.to_s, revision.to_s]
      end

      [source.to_s, "HEAD"]
    end

    def git_source_submodules?(source)
      source.respond_to?(:submodules) && !!source.submodules
    end

    def git_mutex_for(repo_path)
      @git_mutexes_lock ||= Thread::Mutex.new
      @git_mutexes_lock.synchronize do
        @git_mutexes ||= {}
        @git_mutexes[repo_path] ||= Thread::Mutex.new
      end
    end

    private

    # -- Path helpers ---------------------------------------------------------

    def gemfile_path
      File.join(@root, "Gemfile")
    end

    def lockfile_path
      File.join(@root, "Gemfile.lock")
    end

    # -- Credentials ----------------------------------------------------------

    def register_credentials(gf, lf)
      @credentials ||= Credentials.new
      @credentials.register_sources(gf.sources)
      @credentials.register_dependencies(gf.dependencies)
      @credentials.register_lockfile_sources(lf.sources) if lf
    end

    # -- Index fetching -------------------------------------------------------

    def fetch_all_indexes(gf, cache_layout)
      gf.sources.each do |source|
        fetch_index(source, cache_layout)
      end
    end

    def fetch_index(source, cache_layout)
      return unless source.respond_to?(:remotes)

      source.remotes.each do |_remote|
        cache_layout.ensure_dir(cache_layout.index_path(source))
      end
    end

    def clone_all_git_sources(gf, cache_layout)
      git_sources = gf.sources.select { |s| s.is_a?(Source::Git) }
      git_sources.each do |source|
        clone_git_source(source, cache_layout)
      end
    end

    def clone_git_source(source, cache_layout)
      return unless source.respond_to?(:uri)

      git_dir = cache_layout.git_path(source.uri)
      if Dir.exist?(git_dir)
        result = fetch_git_repo(git_dir)
        return unless result == :reclone
      end

      clone_git_repo(source.uri, git_dir)
    end

    # -- Resolution -----------------------------------------------------------

    def run_resolve(gf, lf, cache_layout)
      @credentials ||= Credentials.new

      if lf &&
         lockfile_current?(gf, lf) &&
         lockfile_dependency_graph_valid?(lf) &&
         lockfile_git_source_mapping_valid?(lf, cache_layout)
        return lockfile_to_resolved(lf)
      end

      run_full_resolve(gf, lf, cache_layout)
    end

    def run_full_resolve(gf, lf, cache_layout)
      @credentials ||= Credentials.new

      default_uri = gf.sources.first&.dig(:uri) || "https://rubygems.org"
      all_uris = Set.new([default_uri])
      gf.sources.each do |src|
        all_uris << src[:uri] if src[:type] == :rubygems && src[:uri]
      end

      gf.dependencies.each do |dep|
        if dep.source_options[:source]
          all_uris << dep.source_options[:source]
        end
      end

      clients = {}
      all_uris.each do |uri|
        clients[uri] = Index::Client.new(uri, credentials: @credentials)
      end
      default_client = clients[default_uri]

      source_map = {}
      gf.dependencies.each do |dep|
        src = dep.source_options[:source]
        source_map[dep.name] = src if src
      end

      path_gems = {}
      git_source_metadata_cache = {}
      gf.dependencies.each do |dep|
        opts = dep.source_options
        next unless opts[:path] || opts[:git]

        version = "0"
        deps = []

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

        if opts[:git]
          git_source = find_matching_git_source(Array(lf&.sources), opts) || find_matching_git_source(gf.sources, opts)
          revision_hint = git_source&.revision || git_source&.ref || opts[:ref] || opts[:branch] || opts[:tag] || "HEAD"
          git_repo = cache_layout&.git_path(opts[:git])
          if git_repo && Dir.exist?(git_repo)
            result = fetch_git_repo(git_repo)
            clone_git_repo(opts[:git], git_repo) if result == :reclone
          elsif git_repo
            clone_git_repo(opts[:git], git_repo)
          end
          if git_repo && Dir.exist?(git_repo)
            begin
              resolved_revision = resolve_git_revision(git_repo, revision_hint)
              cache_key = "#{opts[:git]}@#{resolved_revision}"
              git_metadata = git_source_metadata_cache[cache_key]
              unless git_metadata
                git_metadata = build_git_path_gems_for_revision(
                  git_repo,
                  resolved_revision,
                  glob: opts[:glob],
                  source_desc: opts[:git],
                )
                git_source_metadata_cache[cache_key] = git_metadata
              end
              path_gems.merge!(git_metadata)
              current = git_metadata[dep.name]
              if current
                version = current[:version]
                deps = current[:dependencies]
              end
            rescue StandardError
              # Fall back to lockfile version below.
            end
          end

          if lf && version == "0"
            locked_spec = lf.specs.find { |s| s[:name] == dep.name }
            version = locked_spec[:version] if locked_spec
          end
        end

        source_desc = opts[:path] || opts[:git] || "local"
        path_gems[dep.name] = { version: version, dependencies: deps, source: source_desc }
      end

      locked = {}
      if lf
        lf.specs.each { |s| locked[s[:name]] = s[:version] }
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
        dependencies: gf.dependencies,
        locked_specs: locked,
      )
      resolver.resolve
    end

    # -- Lockfile validation --------------------------------------------------

    def lockfile_current?(gf, lf)
      return false unless lf

      locked_names = Set.new(lf.specs.map { |s| s[:name] })
      gf.dependencies.all? do |dep|
        next true unless dependency_relevant_for_local_platform?(dep)

        locked_names.include?(dep.name)
      end
    end

    def lockfile_dependency_graph_valid?(lf)
      return false unless lf

      specs = Array(lf.specs)
      return false if specs.empty?

      by_name = Hash.new { |h, k| h[k] = [] }
      specs.each { |spec| by_name[spec[:name].to_s] << spec }

      specs.all? do |spec|
        Array(spec[:dependencies]).all? do |dep|
          dep_name = dep[:name].to_s
          next true if dep_name == "bundler"

          dep_reqs = Array(dep[:version_reqs])
          req = Gem::Requirement.new(dep_reqs.empty? ? [">= 0"] : dep_reqs)
          by_name[dep_name].any? { |candidate| req.satisfied_by?(Gem::Version.new(candidate[:version].to_s)) }
        end
      end
    rescue StandardError
      false
    end

    def lockfile_git_source_mapping_valid?(lf, cache_layout)
      return true unless lf && cache_layout

      git_specs = Array(lf.specs).select { |s| s[:source].is_a?(Source::Git) }
      return true if git_specs.empty?

      by_source = git_specs.group_by { |s| s[:source] }
      by_source.each do |source, specs|
        uri, revision = git_source_ref(source)
        git_repo = cache_layout.git_path(uri)
        next unless Dir.exist?(git_repo)

        resolved_revision = begin
          resolve_git_revision(git_repo, revision)
        rescue InstallError
          nil
        end
        return false unless resolved_revision

        gemspec_paths = gemspec_paths_in_git_revision(git_repo, resolved_revision)
        gemspec_names = gemspec_paths.keys.to_set
        return false if gemspec_names.empty?

        specs.each do |spec|
          return false unless gemspec_names.include?(spec[:name].to_s)
        end
      end

      true
    end

    def lockfile_to_resolved(lf)
      local_plat = Platform.local_platform

      by_gem = Hash.new { |h, k| h[k] = [] }
      lf.specs.each { |ls| by_gem[[ls[:name], ls[:version]]] << ls }

      by_gem.map do |(_name, _version), specs|
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
    end

    # -- Spec adjustment ------------------------------------------------------

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
        key = SpecUtils.full_key(spec)
        seen[key] ||= spec
      end
      seen.values
    end

    def filter_excluded_gems(resolved, gf)
      excluded = excluded_gem_names(gf, resolved: resolved)
      return resolved if excluded.empty?

      resolved.reject { |spec| excluded.include?(spec.name) }
    end

    def compute_excluded_groups(gf)
      optional = Set.new(Array(gf.optional_groups))
      without = Set.new(Array(@without_groups))
      with = Set.new(Array(@with_groups))

      excluded = optional - with
      excluded.merge(without)
      excluded
    end

    def exclude_transitive_deps(directly_excluded, resolved, gem_groups)
      dep_graph = {}
      resolved.each do |spec|
        dep_names = Array(spec.dependencies).filter_map do |dep|
          if dep.is_a?(Hash)
            dep[:name] || dep["name"]
          elsif dep.respond_to?(:name)
            dep.name
          end
        end
        dep_graph[spec.name] = dep_names
      end

      all_names = Set.new(resolved.map(&:name))

      included_roots = gem_groups.keys.reject { |n| directly_excluded.include?(n) }

      reachable = Set.new
      queue = included_roots.dup
      while (name = queue.shift)
        next if reachable.include?(name)
        reachable << name
        (dep_graph[name] || []).each { |dep| queue << dep }
      end

      all_names - reachable
    end

    # -- Gemspec helpers ------------------------------------------------------

    def find_gemspec(path, gem_name, glob: nil)
      return nil unless Dir.exist?(path)

      glob_pattern = glob || Source::Path::DEFAULT_GLOB
      candidates = [
        File.join(path, "#{gem_name}.gemspec"),
        *Dir.glob(File.join(path, glob_pattern)),
        *Dir.glob(File.join(path, "*.gemspec")),
      ].uniq

      candidates.each do |gs|
        next unless File.exist?(gs)
        begin
          spec = SpecUtils.load_gemspec(gs, isolate: true)
          return spec if spec
        rescue SystemExit, StandardError
          nil
        end
      end
      nil
    end

    def find_git_gemspec(git_repo, revision, gem_name, glob: nil)
      gemspec_paths = gemspec_paths_in_git_revision(git_repo, revision)
      return nil if gemspec_paths.empty?

      path = gemspec_paths[gem_name.to_s]
      if path.nil? && glob
        glob_regex = git_glob_to_regex(glob)
        path = gemspec_paths.values.find { |candidate| candidate.match?(glob_regex) }
      end
      path ||= gemspec_paths.values.first
      return nil if path.nil?

      load_git_gemspec(git_repo, revision, path)
    rescue StandardError
      nil
    end

    def build_git_path_gems_for_revision(git_repo, revision, glob: nil, source_desc: nil)
      gemspec_paths = gemspec_paths_in_git_revision(git_repo, revision)
      return {} if gemspec_paths.empty?

      glob_regex = glob ? git_glob_to_regex(glob) : nil
      data = {}

      with_git_checkout(git_repo, revision) do |checkout_dir|
        gemspec_paths.each_value do |path|
          next if glob_regex && !path.match?(glob_regex)

          gemspec = load_gemspec_from_checkout(checkout_dir, path)
          next unless gemspec

          deps = gemspec.dependencies
            .select { |d| d.type == :runtime }
            .map do |d|
              requirement_parts = d.requirement.requirements.map { |op, req_version| "#{op} #{req_version}" }
              [d.name, requirement_parts]
            end

          data[gemspec.name] = {
            version: gemspec.version.to_s,
            dependencies: deps,
            source: source_desc || "local",
          }
        end
      end

      data
    rescue StandardError
      {}
    end

    def git_glob_to_regex(glob)
      pattern = glob.to_s
      escaped = Regexp.escape(pattern)
      escaped = escaped.gsub("\\*\\*", ".*")
      escaped = escaped.gsub("\\*", "[^/]*")
      escaped = escaped.gsub("\\?", ".")
      /\A#{escaped}\z/
    end

    def gemspec_paths_in_git_revision(git_repo, revision)
      out, _err, status = git_capture3(
        "-C", git_repo,
        "ls-tree",
        "-r",
        "--name-only",
        revision,
      )
      return {} unless status.success?

      paths = {}
      out.each_line do |line|
        path = line.strip
        next unless path.end_with?(".gemspec")
        name = File.basename(path, ".gemspec")
        paths[name] ||= path
      end
      paths
    rescue StandardError
      {}
    end

    def with_git_checkout(git_repo, revision)
      _out, _err, status = git_capture3(
        "-C", git_repo,
        "checkout", "-f", revision,
      )
      return nil unless status.success?

      yield git_repo if block_given?
    end

    def load_gemspec_from_checkout(checkout_dir, gemspec_path)
      absolute_gemspec = File.join(checkout_dir, gemspec_path)
      return nil unless File.exist?(absolute_gemspec)

      SpecUtils.load_gemspec(absolute_gemspec, isolate: true)
    rescue SystemExit, StandardError
      nil
    end

    def load_git_gemspec(git_repo, revision, gemspec_path)
      return nil if gemspec_path.to_s.empty?

      with_git_checkout(git_repo, revision) do |checkout_dir|
        load_gemspec_from_checkout(checkout_dir, gemspec_path)
      end
    rescue StandardError
      nil
    end

    # -- Platform helpers -----------------------------------------------------

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

    # -- Source matching helpers -----------------------------------------------

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
  end
end
