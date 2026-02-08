# frozen_string_literal: true

require_relative "dependency"
require_relative "../source/path"

module Scint
  module Gemfile
    # Result of parsing a Gemfile.
    ParseResult = Struct.new(:dependencies, :sources, :ruby_version, :platforms, keyword_init: true)

    # Evaluates a Gemfile using instance_eval, just like stock bundler.
    # Supports the full Gemfile DSL: source, gem, group, platforms, git_source,
    # git, path, eval_gemfile, ruby, gemspec, and user-defined methods.
    class Parser
      def self.parse(gemfile_path)
        parser = new(gemfile_path)
        parser.evaluate
        ParseResult.new(
          dependencies: parser.parsed_dependencies,
          sources: parser.parsed_sources.uniq,
          ruby_version: parser.parsed_ruby_version,
          platforms: parser.parsed_platforms,
        )
      end

      # Accessors that don't collide with DSL method names
      def parsed_dependencies;  @dependencies;  end
      def parsed_sources;       @sources;       end
      def parsed_ruby_version;  @ruby_version;  end
      def parsed_platforms;     @declared_platforms; end

      def initialize(gemfile_path)
        @gemfile_path = File.expand_path(gemfile_path)
        @dependencies = []
        @sources = []
        @git_sources = {}
        @current_groups = []
        @current_platforms = []
        @current_source_options = {}
        @ruby_version = nil
        @declared_platforms = []

        add_default_git_sources
      end

      def evaluate
        contents = File.read(@gemfile_path)
        instance_eval(contents, @gemfile_path, 1)
      rescue SyntaxError => e
        raise GemfileError, "Syntax error in #{File.basename(@gemfile_path)}: #{e.message}"
      rescue ScriptError, StandardError => e
        raise GemfileError, "Error evaluating #{File.basename(@gemfile_path)}: #{e.message}"
      end

      # --- Gemfile DSL methods ---

      def source(url, &blk)
        url = url.to_s
        if block_given?
          old_source = @current_source_options.dup
          @current_source_options = { source: url }
          @sources << { type: :rubygems, uri: url }
          yield
          @current_source_options = old_source
        else
          @sources << { type: :rubygems, uri: url }
        end
      end

      def gem(name, *args)
        options = args.last.is_a?(Hash) ? args.pop.dup : {}
        version_reqs = args.flatten

        # Collect groups
        groups = @current_groups.dup
        if options[:group] || options[:groups]
          extra = Array(options.delete(:group)) + Array(options.delete(:groups))
          groups.concat(extra.map(&:to_sym))
        end
        groups = [:default] if groups.empty?

        # Collect platforms
        plats = @current_platforms.dup
        if options[:platform] || options[:platforms]
          extra = Array(options.delete(:platform)) + Array(options.delete(:platforms))
          plats.concat(extra.map(&:to_sym))
        end

        # Handle require paths
        require_paths = nil
        if options.key?(:require)
          req = options.delete(:require)
          require_paths = req == false ? [] : Array(req)
        end

        # Build source options from git_source helpers and explicit options
        source_opts = @current_source_options.dup

        # Handle custom git sources (e.g. shopify: "repo-name")
        @git_sources.each do |src_name, block|
          if options.key?(src_name)
            repo = options.delete(src_name)
            result = block.call(repo)
            if result.is_a?(Hash)
              source_opts.merge!(result.transform_keys(&:to_sym))
            else
              source_opts[:git] = result.to_s
            end
          end
        end

        # Handle explicit git/github/path/source options
        if options[:github]
          repo = options.delete(:github)
          # Handle pull request URLs
          if repo =~ %r{\Ahttps://github\.com/([^/]+/[^/]+)/pull/(\d+)\z}
            source_opts[:git] = "https://github.com/#{$1}.git"
            source_opts[:ref] = "refs/pull/#{$2}/head"
          else
            repo = "#{repo}/#{repo}" unless repo.include?("/")
            source_opts[:git] = "https://github.com/#{repo}.git"
          end
        end

        if options[:git]
          source_opts[:git] = options.delete(:git)
        end

        if options[:path]
          path_val = options.delete(:path)
          # Resolve relative paths against the Gemfile's directory
          unless path_val.start_with?("/")
            path_val = File.expand_path(path_val, File.dirname(@gemfile_path))
          end
          source_opts[:path] = path_val
        end

        # Internal/source metadata used by lockfile generation.
        source_opts[:glob] = options.delete(:glob) if options.key?(:glob)
        source_opts[:gemspec_generated] = options.delete(:gemspec_generated) if options.key?(:gemspec_generated)
        source_opts[:gemspec_primary] = options.delete(:gemspec_primary) if options.key?(:gemspec_primary)

        if options[:source]
          source_opts[:source] = options.delete(:source)
        end

        # Copy over git-related options
        [:branch, :ref, :tag, :submodules].each do |key|
          source_opts[key] = options.delete(key) if options.key?(key)
        end

        # Ignore options we don't use but shouldn't error on
        options.delete(:force_ruby_platform)
        options.delete(:install_if)

        dep = Dependency.new(
          name,
          version_reqs: version_reqs,
          groups: groups,
          platforms: plats,
          require_paths: require_paths,
          source_options: source_opts,
        )

        @dependencies << dep
      end

      def group(*names, **opts, &blk)
        old_groups = @current_groups.dup
        @current_groups.concat(names.map(&:to_sym))
        yield
      ensure
        @current_groups = old_groups
      end

      def platforms(*names, &blk)
        old_platforms = @current_platforms.dup
        @current_platforms.concat(names.map(&:to_sym))
        yield
      ensure
        @current_platforms = old_platforms
      end
      alias_method :platform, :platforms

      def git_source(name, &block)
        raise GemfileError, "git_source requires a block" unless block_given?
        @git_sources[name.to_sym] = block
      end

      def git(url, **opts, &blk)
        raise GemfileError, "git requires a block" unless block_given?
        old_source = @current_source_options.dup
        @current_source_options = { git: url }.merge(opts)
        yield
      ensure
        @current_source_options = old_source
      end

      def path(path_str, **opts, &blk)
        old_source = @current_source_options.dup
        resolved = if path_str.start_with?("/")
          path_str
        else
          File.expand_path(path_str, File.dirname(@gemfile_path))
        end
        @current_source_options = { path: resolved }.merge(opts)
        yield if block_given?
      ensure
        @current_source_options = old_source
      end

      def eval_gemfile(path)
        expanded = if path.start_with?("/")
          path
        else
          File.expand_path(path, File.dirname(@gemfile_path))
        end
        contents = File.read(expanded)
        instance_eval(contents, expanded, 1)
      end

      def ruby(*versions, **opts)
        version_parts = versions.flatten.compact.map(&:to_s)
        @ruby_version = version_parts.join(", ") unless version_parts.empty?
      end

      def gemspec(opts = {})
        path = opts[:path] || "."
        name = opts[:name]
        glob = opts[:glob] || Scint::Source::Path::DEFAULT_GLOB
        dir = File.expand_path(path, File.dirname(@gemfile_path))
        gemspecs = Dir.glob(File.join(dir, glob)).sort
        # Just record we have a gemspec source -- full spec loading is
        # deferred to the resolver/installer.
        gemspecs.each do |gs|
          spec_name = File.basename(gs, ".gemspec")
          next if name && spec_name != name
          gem(
            spec_name,
            path: File.dirname(gs),
            glob: glob,
            gemspec_generated: true,
            gemspec_primary: File.expand_path(File.dirname(gs)) == dir,
          )
        end
      end

      def install_if(*conditions, &blk)
        raise GemfileError, "install_if requires a block" unless block_given?
        return unless conditions.all? { |condition| condition_truthy?(condition) }

        yield
      end

      # Silently ignore plugin declarations
      def plugin(*args); end

      # Allow user-defined methods (like `in_repo_gem`) and unknown DSL
      # methods to raise a clear error.
      def method_missing(name, *args, &block)
        raise GemfileError, "Undefined local variable or method `#{name}' for Gemfile\n" \
          "  in #{@gemfile_path}"
      end

      def respond_to_missing?(name, include_private = false)
        false
      end

      private

      def condition_truthy?(condition)
        return condition.call if condition.respond_to?(:call)

        !!condition
      end

      def add_default_git_sources
        git_source(:github) do |repo_name|
          if repo_name =~ %r{\Ahttps://github\.com/([^/]+/[^/]+)/pull/(\d+)\z}
            {
              git: "https://github.com/#{$1}.git",
              ref: "refs/pull/#{$2}/head",
            }
          else
            repo_name = "#{repo_name}/#{repo_name}" unless repo_name.include?("/")
            "https://github.com/#{repo_name}.git"
          end
        end

        git_source(:gist) do |repo_name|
          "https://gist.github.com/#{repo_name}.git"
        end

        git_source(:bitbucket) do |repo_name|
          user, repo = repo_name.split("/")
          repo ||= user
          "https://#{user}@bitbucket.org/#{user}/#{repo}.git"
        end
      end
    end
  end
end
