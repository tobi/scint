# frozen_string_literal: true

require_relative "../fs"

module Scint
  module Cache
    class MetadataStore
      def initialize(path)
        @path = path
        @data = nil
        @mutex = Thread::Mutex.new
      end

      # Load specs hash from disk. Returns {} if file missing or corrupt.
      def load
        @mutex.synchronize do
          return @data if @data
          @data = load_from_disk
        end
      end

      # Save specs hash to disk atomically.
      def save(specs_hash)
        @mutex.synchronize do
          @data = specs_hash
          FS.atomic_write(@path, Marshal.dump(specs_hash))
        end
      end

      # Check if a gem is installed. specs_hash keys are "name-version" or "name-version-platform".
      def installed?(name, version, platform = "ruby")
        data = load
        key = cache_key(name, version, platform)
        data.key?(key)
      end

      # Add a single entry.
      def add(name, version, platform = "ruby")
        @mutex.synchronize do
          @data ||= load_from_disk
          key = cache_key(name, version, platform)
          @data[key] = true
          FS.atomic_write(@path, Marshal.dump(@data))
        end
      end

      # Remove a single entry.
      def remove(name, version, platform = "ruby")
        @mutex.synchronize do
          @data ||= load_from_disk
          key = cache_key(name, version, platform)
          @data.delete(key)
          FS.atomic_write(@path, Marshal.dump(@data))
        end
      end

      private

      def cache_key(name, version, platform)
        if platform && platform.to_s != "ruby" && platform.to_s != ""
          "#{name}-#{version}-#{platform}"
        else
          "#{name}-#{version}"
        end
      end

      def load_from_disk
        return {} unless File.exist?(@path)
        Marshal.load(File.binread(@path))
      rescue ArgumentError, TypeError, EOFError
        {}
      end
    end
  end
end
