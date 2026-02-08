# frozen_string_literal: true

require_relative "../spec_utils"

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
        specs_by_source = {}
        @data.sources.each { |s| specs_by_source[s] = [] }

        @data.specs.each do |spec|
          target = match_source_for_spec(spec) || @data.sources.first
          next unless target

          specs_by_source[target] ||= []
          specs_by_source[target] << spec
        end

        emitted = false
        @data.sources.each do |source|
          source_specs = specs_by_source[source] || []
          next if source_specs.empty?

          out << "\n" if emitted
          emitted = true

          out << source.to_lock
          add_specs(out, source_specs)
        end
      end

      def match_source_for_spec(spec)
        spec_source = spec.is_a?(Hash) ? spec[:source] : spec.source
        return nil unless spec_source

        @data.sources.find { |source| source_matches?(source, spec_source) }
      end

      def source_matches?(source, spec_source)
        return true if source.equal?(spec_source)
        return true if source == spec_source

        spec_key = normalize_source_key(spec_source)
        return false unless spec_key

        if source.respond_to?(:remotes)
          source.remotes.any? { |remote| normalize_source_key(remote) == spec_key }
        elsif source.respond_to?(:uri)
          normalize_source_key(source.uri) == spec_key
        else
          normalize_source_key(source) == spec_key
        end
      end

      def normalize_source_key(source_ref)
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

      def add_specs(out, specs)
        # Sort by full name (name-version-platform) for consistency
        sorted = specs.sort_by do |s|
          if s.is_a?(Hash)
            SpecUtils.full_name_for(s[:name], s[:version], s[:platform])
          else
            SpecUtils.full_name_for(s.name, s.version, s.platform)
          end
        end

        sorted.each do |spec|
          name, version, deps = if spec.is_a?(Hash)
            [spec[:name], spec[:version], spec[:dependencies] || []]
          else
            [spec.name, spec.version, spec.dependencies || []]
          end

          # Format: "    name (version)" or "    name (version-platform)"
          platform_str = SpecUtils.platform_str(spec)
          version_str = platform_str == "ruby" ? version.to_s : "#{version}-#{platform_str}"
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

        @data.checksums.each do |key, values|
          rendered_key = format_checksum_key(key)
          if values && !values.empty?
            out << "  #{rendered_key} #{values.join(",")}\n"
          else
            out << "  #{rendered_key}\n"
          end
        end
      end

      def format_checksum_key(key)
        match = key.to_s.match(/\A(.+)-(\d[^-]*)(?:-(.+))?\z/)
        return key unless match

        name = match[1]
        version = match[2]
        platform = match[3]
        version_str = platform ? "#{version}-#{platform}" : version
        "#{name} (#{version_str})"
      end

      def add_ruby_version(out)
        return unless @data.ruby_version
        out << "\nRUBY VERSION\n"
        out << "   #{@data.ruby_version}\n"
      end

      def add_bundled_with(out)
        return unless @data.bundler_version
        out << "\nBUNDLED WITH\n"
        out << "   #{@data.bundler_version}\n"
      end

    end
  end
end
