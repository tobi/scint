# frozen_string_literal: true

module Bundler2
  module Index
    class Parser
      # Parse the compact index "names" endpoint response.
      # Returns array of gem name strings.
      def parse_names(data)
        return [] if data.nil? || data.empty?
        lines = strip_header(data)
        lines
      end

      # Parse the compact index "versions" endpoint response.
      # Returns a hash:
      #   { name => [[name, version, platform], ...], ... }
      # Also stores checksums accessible via #info_checksums.
      def parse_versions(data)
        @versions_by_name = Hash.new { |h, k| h[k] = [] }
        @info_checksums = {}

        return @versions_by_name if data.nil? || data.empty?

        strip_header(data).each do |line|
          line.freeze

          name_end = line.index(" ")
          next unless name_end

          versions_end = line.index(" ", name_end + 1)
          name = line[0, name_end].freeze

          if versions_end
            versions_string = line[name_end + 1, versions_end - name_end - 1]
            @info_checksums[name] = line[versions_end + 1, line.size - versions_end - 1]
          else
            versions_string = line[name_end + 1, line.size - name_end - 1]
            @info_checksums[name] = ""
          end

          versions_string.split(",") do |version|
            delete = version.delete_prefix!("-")
            parts = version.split("-", 2)
            entry = parts.unshift(name)
            if delete
              @versions_by_name[name].delete(entry)
            else
              @versions_by_name[name] << entry
            end
          end
        end

        @versions_by_name
      end

      # Returns checksums collected during parse_versions.
      # Keys are gem names, values are checksum strings.
      def info_checksums
        @info_checksums || {}
      end

      # Parse a compact index "info/{gem_name}" endpoint response.
      # Returns array of entries:
      #   [name, version, platform, deps_hash, requirements_hash]
      #
      # deps_hash: { "dep_name" => "version_constraints", ... }
      # requirements_hash: { "ruby" => ">= 2.7", "rubygems" => ">= 3.0" }
      def parse_info(name, data)
        return [] if data.nil? || data.empty?

        strip_header(data).map do |line|
          parse_info_line(name, line)
        end
      end

      private

      # Strip the "---\n" header that compact index responses may include.
      def strip_header(data)
        lines = data.split("\n")
        header = lines.index("---")
        header ? lines[(header + 1)..] : lines
      end

      # Parse a single info line using the compact index format:
      #   VERSION[-PLATFORM] DEP1:REQ1&REQ2,DEP2:REQ3|RUBY_REQ:VAL1&VAL2,RUBYGEMS_REQ:VAL3
      #
      # - Space separates version from the rest
      # - "|" separates dependency list from requirement list
      # - "," separates individual deps or reqs
      # - ":" separates name from version constraints within each dep/req
      # - "&" separates multiple version constraints for one dep/req
      def parse_info_line(name, line)
        version_and_platform, rest = line.split(" ", 2)

        # Split version and platform
        version, platform = version_and_platform.split("-", 2)
        platform ||= "ruby"

        # Split rest into deps and requirements by "|"
        deps = {}
        reqs = {}

        if rest && !rest.empty?
          deps_str, reqs_str = rest.split("|", 2)

          # Parse dependencies
          if deps_str && !deps_str.empty?
            deps_str.split(",").each do |dep_entry|
              parts = dep_entry.split(":")
              dep_name = parts[0]
              next if dep_name.nil? || dep_name.empty?
              dep_name = -dep_name  # freeze and deduplicate
              if parts.size > 1
                deps[dep_name] = parts[1].split("&").join(", ")
              else
                deps[dep_name] = ">= 0"
              end
            end
          end

          # Parse requirements (ruby, rubygems version constraints)
          if reqs_str && !reqs_str.empty?
            reqs_str.split(",").each do |req_entry|
              parts = req_entry.split(":")
              req_name = parts[0]
              next if req_name.nil? || req_name.empty?
              req_name = -req_name.strip
              if parts.size > 1
                reqs[req_name] = parts[1].split("&").join(", ")
              else
                reqs[req_name] = ">= 0"
              end
            end
          end
        end

        [name, version, platform, deps, reqs]
      end
    end
  end
end
