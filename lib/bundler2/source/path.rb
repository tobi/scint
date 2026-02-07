# frozen_string_literal: true

require_relative "base"

module Bundler2
  module Source
    class Path < Base
      attr_reader :path, :glob

      DEFAULT_GLOB = "{,*,*/*}.gemspec"

      def initialize(path:, glob: nil, name: nil, version: nil)
        @path = path.to_s
        @glob = glob || DEFAULT_GLOB
        @name = name
        @version = version
      end

      def self.from_lock(options)
        new(
          path: options.delete("remote"),
          glob: options["glob"],
          name: options["name"],
          version: options["version"],
        )
      end

      def name
        @name || File.basename(@path)
      end

      def uri
        @path
      end

      def specs
        [] # Loaded from gemspec on disk
      end

      def fetch_spec(name, version, platform = "ruby")
        nil
      end

      def cache_slug
        name
      end

      def to_lock
        out = String.new("PATH\n")
        out << "  remote: #{@path}\n"
        out << "  glob: #{@glob}\n" unless @glob == DEFAULT_GLOB
        out << "  specs:\n"
        out
      end

      def eql?(other)
        other.is_a?(Path) &&
          File.expand_path(path) == File.expand_path(other.path)
      end

      def hash
        [self.class, File.expand_path(path)].hash
      end

      def to_s
        "path: #{@path}"
      end
    end
  end
end
