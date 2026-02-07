# frozen_string_literal: true

module Bundler2
  module Resolver
    # Bridges compact index data and the PubGrub resolver.
    # Converts compact index info entries into version lists and dependency hashes.
    #
    # Supports multiple sources: each gem can be routed to a specific
    # Index::Client based on source_map (gem_name => source_uri).
    class Provider
      # default_client: Index::Client for the default source (rubygems.org)
      # clients: hash { source_uri_string => Index::Client } for all sources
      # source_map: hash { gem_name => source_uri_string } for gems with explicit sources
      # path_gems: hash { gem_name => { version:, dependencies: } } for path/git gems
      # locked_specs: hash { name => version_string } for locked version preferences
      # platforms: array of platform strings to match against
      def initialize(default_client, clients: {}, source_map: {}, path_gems: {},
                     locked_specs: {}, platforms: nil)
        @default_client = default_client
        @clients = clients
        @source_map = source_map
        @path_gems = path_gems
        @locked_specs = locked_specs
        @platforms = platforms || default_platforms
        @versions_cache = {}
        @deps_cache = {}
        @info_cache = {}
        @mutex = Thread::Mutex.new
      end

      # For backward compat and use in resolver (e.g. source_uri on resolved specs)
      def index_client
        @default_client
      end

      # Returns the source URI for a gem name.
      def source_uri_for(name)
        if @path_gems.key?(name)
          @path_gems[name][:source] || "path"
        elsif @source_map.key?(name)
          @source_map[name]
        else
          @default_client.source_uri
        end
      end

      # Returns the Index::Client for a given gem name.
      def client_for(name)
        source_uri = @source_map[name]
        if source_uri
          @clients[source_uri] || @default_client
        else
          @default_client
        end
      end

      # Returns sorted array of Gem::Version for a given gem name,
      # filtered to matching platforms.
      def versions_for(name)
        @versions_cache[name] ||= begin
          # Path/git gems: return the single known version
          if @path_gems.key?(name)
            pg = @path_gems[name]
            [Gem::Version.new(pg[:version] || "0")]
          else
            entries = info_for(name)
            versions = {}
            entries.each do |_name, version, platform, _deps, _reqs|
              next unless platform_match?(platform)
              ver = Gem::Version.new(version)
              versions[version] ||= ver
            end
            versions.values.sort
          end
        end
      end

      # Returns dependency hash for a specific gem name + version.
      # { "dep_name" => Gem::Requirement, ... }
      def dependencies_for(name, version)
        key = "#{name}-#{version}"
        @deps_cache[key] ||= begin
          # Path/git gems: return their declared dependencies
          if @path_gems.key?(name)
            pg = @path_gems[name]
            deps = {}
            (pg[:dependencies] || []).each do |dep_name, dep_req_str|
              deps[dep_name] = Gem::Requirement.new(dep_req_str || ">= 0")
            end
            deps
          else
            version_str = version.to_s
            entries = info_for(name)
            deps = {}

            entries.each do |_name, ver, platform, dep_hash, _reqs|
              next unless ver == version_str && platform_match?(platform)
              dep_hash.each do |dep_name, dep_req_str|
                # Merge constraints from all matching platform entries
                req = Gem::Requirement.new(dep_req_str.split(", "))
                deps[dep_name] = if deps[dep_name]
                  merge_requirements(deps[dep_name], req)
                else
                  req
                end
              end
            end

            deps
          end
        end
      end

      # Check if a gem version has native extensions.
      # Approximated by checking if there's a platform-specific variant.
      def has_extensions?(name, version)
        return false if @path_gems.key?(name)

        version_str = version.to_s
        entries = info_for(name)
        has_platform_specific = false
        entries.each do |_name, ver, platform, _deps, _reqs|
          next unless ver == version_str
          has_platform_specific = true if platform != "ruby"
        end
        has_platform_specific
      end

      # Choose the most appropriate platform for a resolved version,
      # preferring local binary gems over ruby source gems when available.
      def preferred_platform_for(name, version)
        return "ruby" if @path_gems.key?(name)

        version_str = version.to_s
        entries = info_for(name).select do |_n, ver, platform, _deps, _reqs|
          ver == version_str && platform_match?(platform)
        end
        return "ruby" if entries.empty?

        local_platforms = @platforms.reject { |p| p == "ruby" }
        non_ruby = entries.map { |e| e[2] }.compact.reject { |p| p == "ruby" }.uniq

        preferred = non_ruby.find do |platform|
          local_platforms.any? do |local|
            spec_plat = platform.is_a?(Gem::Platform) ? platform : Gem::Platform.new(platform)
            local_plat = local.is_a?(Gem::Platform) ? local : Gem::Platform.new(local)
            Gem::Platform.match_gem?(spec_plat, local_plat)
          end
        end
        return preferred if preferred

        entries.any? { |e| e[2] == "ruby" } ? "ruby" : entries.first[2].to_s
      end

      # Returns the locked version for a gem, if any.
      def locked_version(name)
        v = @locked_specs[name]
        v ? Gem::Version.new(v) : nil
      end

      # Prefetch info for a batch of gem names, routing to the correct client.
      def prefetch(names)
        # Filter to names we haven't cached yet, skip path/git gems
        uncached = names.reject { |n| @info_cache.key?(n) || @path_gems.key?(n) }
        return if uncached.empty?

        # Group by client
        by_client = Hash.new { |h, k| h[k] = [] }
        uncached.each do |name|
          by_client[client_for(name)] << name
        end

        by_client.each do |client, client_names|
          results = client.prefetch(client_names)
          next unless results

          @mutex.synchronize do
            results.each do |name, data|
              @info_cache[name] = data
            end
          end
        end
      end

      # Returns true if the gem is a path or git source gem.
      def path_or_git_gem?(name)
        @path_gems.key?(name)
      end

      private

      def info_for(name)
        @info_cache[name] ||= client_for(name).fetch_info(name)
      end

      def default_platforms
        local = Platform.local_platform.to_s
        platforms = ["ruby"]
        platforms << local unless local == "ruby"
        platforms
      end

      def platform_match?(spec_platform)
        return true if spec_platform.nil? || spec_platform == "ruby"
        @platforms.any? do |plat|
          if plat == "ruby"
            spec_platform == "ruby"
          else
            spec_plat = spec_platform.is_a?(Gem::Platform) ? spec_platform : Gem::Platform.new(spec_platform)
            local_plat = plat.is_a?(Gem::Platform) ? plat : Gem::Platform.new(plat)
            Gem::Platform.match_gem?(spec_plat, local_plat)
          end
        end
      end

      def merge_requirements(req1, req2)
        # Combine requirement constraints
        combined = req1.requirements + req2.requirements
        Gem::Requirement.new(combined.map { |op, v| "#{op} #{v}" })
      end
    end
  end
end
