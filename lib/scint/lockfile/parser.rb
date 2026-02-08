# frozen_string_literal: true

require_relative "../source/rubygems"
require_relative "../source/git"
require_relative "../source/path"
require_relative "../spec_utils"

module Scint
  module Lockfile
    # Data returned by the lockfile parser.
    LockfileData = Struct.new(
      :specs, :dependencies, :platforms, :sources,
      :bundler_version, :ruby_version, :checksums,
      keyword_init: true,
    )

    # Parses a standard Gemfile.lock file into structured data.
    # Compatible with the format produced by stock bundler.
    class Parser
      BUNDLED      = "BUNDLED WITH"
      DEPENDENCIES = "DEPENDENCIES"
      CHECKSUMS    = "CHECKSUMS"
      PLATFORMS    = "PLATFORMS"
      RUBY         = "RUBY VERSION"
      GIT          = "GIT"
      GEM          = "GEM"
      PATH         = "PATH"
      SPECS        = "  specs:"

      OPTIONS = /^  ([a-z]+): (.*)$/i
      SOURCE_TYPES = [GIT, GEM, PATH].freeze

      # Regex for spec/dependency lines:
      # 2 spaces = dependency, 4 spaces = spec, 6 spaces = spec dependency
      NAME_VERSION = /
        ^(\s{2}|\s{4}|\s{6})(?!\s) # exactly 2, 4, or 6 leading spaces
        (.*?)                        # name
        (?:\s\(([^-]*)               # version in parens
        (?:-(.*))?\))?               # optional platform after dash
        (!)?                         # optional pinned marker
        (?:\s([^\s]+))?              # optional checksum
        $
      /x

      # Accepts either lockfile contents or a file path.
      def self.parse(lockfile_or_contents)
        contents =
          if lockfile_or_contents.is_a?(String) && File.exist?(lockfile_or_contents)
            File.read(lockfile_or_contents)
          else
            lockfile_or_contents.to_s
          end
        new(contents).parse
      end

      def initialize(lockfile_contents)
        @contents = lockfile_contents
        @specs = []
        @dependencies = {}
        @platforms = []
        @sources = []
        @bundler_version = nil
        @ruby_version = nil
        @checksums = nil

        @parse_method = nil
        @current_source = nil
        @current_spec = nil
        @source_type = nil
        @source_opts = {}
      end

      def parse
        if @contents.match?(/(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)/)
          raise LockfileError, "Lockfile contains merge conflicts"
        end

        @contents.each_line do |line|
          line.chomp!

          # Blank lines reset nothing; skip them
          next if line.strip.empty?

          if SOURCE_TYPES.include?(line)
            @parse_method = :parse_source
            @source_type = line
            @source_opts = {}
            @current_source = nil
            next
          elsif line == DEPENDENCIES
            @parse_method = :parse_dependency
            next
          elsif line == CHECKSUMS
            @checksums = {}
            @parse_method = :parse_checksum
            next
          elsif line == PLATFORMS
            @parse_method = :parse_platform
            next
          elsif line == RUBY
            @parse_method = :parse_ruby
            next
          elsif line == BUNDLED
            @parse_method = :parse_bundled_with
            next
          elsif line =~ /^[^\s]/
            # Unknown section header
            @parse_method = nil
            next
          end

          next unless @parse_method

          case @parse_method
          when :parse_source then parse_source(line)
          when :parse_dependency then parse_dependency(line)
          when :parse_checksum then parse_checksum(line)
          when :parse_platform then parse_platform(line)
          when :parse_ruby then parse_ruby(line)
          when :parse_bundled_with then parse_bundled_with(line)
          end
        end

        LockfileData.new(
          specs: @specs,
          dependencies: @dependencies,
          platforms: @platforms,
          sources: @sources,
          bundler_version: @bundler_version,
          ruby_version: @ruby_version,
          checksums: @checksums,
        )
      end

      private

      def parse_source(line)
        case line
        when SPECS
          @current_source = build_source(@source_type, @source_opts)
          @sources << @current_source if @current_source
        when OPTIONS
          key = $1
          value = $2
          value = true if value == "true"
          value = false if value == "false"

          if @source_opts[key]
            @source_opts[key] = Array(@source_opts[key])
            @source_opts[key] << value
          else
            @source_opts[key] = value
          end
        else
          parse_spec(line)
        end
      end

      def parse_spec(line)
        return unless line =~ NAME_VERSION
        spaces = $1
        name = $2.freeze
        version = $3
        platform = $4

        if spaces.length == 4
          # This is a spec line (top-level spec under a source)
          spec = {
            name: name,
            version: version,
            platform: platform || "ruby",
            dependencies: [],
            source: @current_source,
            checksum: nil,
          }
          @specs << spec
          @current_spec = spec
        elsif spaces.length == 6 && @current_spec
          # This is a dependency of the current spec
          dep_versions = version ? version.split(",").map(&:strip) : [">= 0"]
          @current_spec[:dependencies] << { name: name, version_reqs: dep_versions }
        end
      end

      def parse_dependency(line)
        return unless line =~ NAME_VERSION
        spaces = $1
        return unless spaces.length == 2

        name = $2.freeze
        version = $3
        pinned = $5

        version_reqs = version ? version.split(",").map(&:strip) : [">= 0"]

        @dependencies[name] = {
          name: name,
          version_reqs: version_reqs,
          pinned: pinned == "!",
        }
      end

      def parse_checksum(line)
        return unless line =~ NAME_VERSION
        spaces = $1
        return unless spaces.length == 2

        name = $2
        version = $3
        platform = $4 || "ruby"
        checksums_str = $6

        key = SpecUtils.full_name_for(name, version, platform)

        if checksums_str
          @checksums[key] = checksums_str.split(",").map(&:strip)
        else
          @checksums[key] = []
        end
      end

      def parse_platform(line)
        stripped = line.strip
        return if stripped.empty?
        @platforms << stripped
      end

      def parse_ruby(line)
        stripped = line.strip
        return if stripped.empty?
        @ruby_version = stripped
      end

      def parse_bundled_with(line)
        stripped = line.strip
        return if stripped.empty?
        @bundler_version = stripped
      end

      def build_source(type, opts)
        case type
        when GEM
          Source::Rubygems.from_lock(opts.dup)
        when GIT
          Source::Git.from_lock(opts.dup)
        when PATH
          Source::Path.from_lock(opts.dup)
        end
      end
    end
  end
end
