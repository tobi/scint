# frozen_string_literal: true

module Scint
  module Lockfile
    # Writes a standard Gemfile.lock file from structured data.
    # Produces output compatible with stock bundler.
    #
    # Sections in order: source blocks (GEM/GIT/PATH), PLATFORMS,
    # DEPENDENCIES, CHECKSUMS (if present), RUBY VERSION, BUNDLED WITH.
    class Writer
      def self.write(lockfile_data)
        new(lockfile_data).generate
      end

      def initialize(lockfile_data)
        @data = lockfile_data
      end

      def generate
        out = String.new

        add_sources(out)
        add_platforms(out)
        add_dependencies(out)
        add_checksums(out)
        add_ruby_version(out)
        add_bundled_with(out)

        out
      end

      private

      def add_sources(out)
        # Group specs by source, preserving source order.
        # Specs store source as a URI string; sources are Source objects.
        # Match by checking if the spec's source URI matches any remote.
        specs_by_source = {}
        @data.sources.each { |s| specs_by_source[s] = [] }

        @data.specs.each do |spec|
          spec_src = spec.is_a?(Hash) ? spec[:source] : spec.source
          spec_uri = normalize_source_uri(spec_src)

          matched = @data.sources.find do |source|
            if source.respond_to?(:remotes)
              source.remotes.any? { |r| normalize_source_uri(r) == spec_uri }
            elsif source.respond_to?(:uri)
              normalize_source_uri(source.uri) == spec_uri
            else
              source == spec_src
            end
          end

          target = matched || @data.sources.first
          specs_by_source[target] ||= []
          specs_by_source[target] << spec
        end

        first = true
        @data.sources.each do |source|
          out << "\n" unless first
          first = false

          out << source.to_lock
          add_specs(out, specs_by_source[source] || [])
        end
      end

      def normalize_source_uri(uri)
        s = uri.to_s.chomp("/")
        s.sub(%r{^https?://}, "").downcase
      end

      def add_specs(out, specs)
        # Sort by full name (name-version-platform) for consistency
        sorted = specs.sort_by do |s|
          if s.is_a?(Hash)
            n = s[:name]
            v = s[:version]
            p = s[:platform]
            p == "ruby" ? "#{n}-#{v}" : "#{n}-#{v}-#{p}"
          else
            "#{s.name}-#{s.version}#{"-#{s.platform}" if s.platform != "ruby"}"
          end
        end

        sorted.each do |spec|
          name, version, platform, deps = if spec.is_a?(Hash)
            [spec[:name], spec[:version], spec[:platform], spec[:dependencies] || []]
          else
            [spec.name, spec.version, spec.platform, spec.dependencies || []]
          end

          # Format: "    name (version)" or "    name (version-platform)"
          version_str = platform && platform != "ruby" ? "#{version}-#{platform}" : version.to_s
          out << "    #{name} (#{version_str})\n"

          # Dependencies of this spec (6-space indent)
          dep_list = deps.sort_by { |d| d.is_a?(Hash) ? d[:name] : d.name }
          dep_list.each do |dep|
            dep_name, dep_reqs = if dep.is_a?(Hash)
              [dep[:name], dep[:version_reqs]]
            else
              [dep.name, dep.version_reqs]
            end

            if dep_reqs && dep_reqs != [">= 0"]
              out << "      #{dep_name} (#{Array(dep_reqs).join(", ")})\n"
            else
              out << "      #{dep_name}\n"
            end
          end
        end
      end

      def add_platforms(out)
        return if @data.platforms.empty?
        out << "\nPLATFORMS\n"
        @data.platforms.sort.each do |p|
          out << "  #{p}\n"
        end
      end

      def add_dependencies(out)
        return if @data.dependencies.empty?
        out << "\nDEPENDENCIES\n"

        deps = @data.dependencies
        dep_list = if deps.is_a?(Hash)
          deps.values
        else
          deps
        end

        dep_list.sort_by { |d| d.is_a?(Hash) ? d[:name] : d.name }.each do |dep|
          name, reqs, pinned = if dep.is_a?(Hash)
            [dep[:name], dep[:version_reqs], dep[:pinned]]
          else
            [dep.name, dep.version_reqs, dep.pinned]
          end

          out << "  #{name}"
          if reqs && reqs != [">= 0"]
            out << " (#{Array(reqs).join(", ")})"
          end
          out << "!" if pinned
          out << "\n"
        end
      end

      def add_checksums(out)
        return unless @data.checksums
        out << "\nCHECKSUMS\n"

        @data.checksums.sort.each do |key, values|
          if values && !values.empty?
            out << "  #{key} #{values.join(",")}\n"
          else
            out << "  #{key}\n"
          end
        end
      end

      def add_ruby_version(out)
        return unless @data.ruby_version
        out << "\nRUBY VERSION\n"
        out << "  #{@data.ruby_version}\n"
      end

      def add_bundled_with(out)
        return unless @data.bundler_version
        out << "\nBUNDLED WITH\n"
        out << "   #{@data.bundler_version}\n"
      end
    end
  end
end
