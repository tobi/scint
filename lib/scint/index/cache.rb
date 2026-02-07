# frozen_string_literal: true

require "fileutils"
require "digest"

module Scint
  module Index
    class Cache
      attr_reader :directory

      def initialize(cache_dir)
        @directory = File.expand_path(cache_dir)
        @info_dir = File.join(@directory, "info")
        @info_etag_dir = File.join(@directory, "info-etags")
        @info_binary_dir = File.join(@directory, "info-binary")
        @mutex = Thread::Mutex.new

        ensure_dirs
      end

      # Source slug for cache directory naming.
      # e.g. "rubygems.org" or "gems.example.com-private"
      def self.slug_for(uri)
        uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
        path = uri.path.to_s.gsub("/", "-").sub(/^-/, "")
        slug = uri.host.to_s
        slug += path unless path.empty? || path == "-"
        slug
      end

      # Read cached names file.
      def names
        read_file(names_path)
      end

      # Write names file.
      def write_names(data, etag: nil)
        write_file(names_path, data)
        write_file(names_etag_path, etag) if etag
      end

      # Read the ETag for names.
      def names_etag
        read_file(names_etag_path)&.chomp
      end

      # Read cached versions file.
      def versions
        read_file(versions_path)
      end

      # Write versions file. Supports appending for range requests.
      def write_versions(data, etag: nil, append: false)
        if append && File.exist?(versions_path)
          File.open(versions_path, "ab") { |f| f.write(data) }
        else
          write_file(versions_path, data)
        end
        write_file(versions_etag_path, etag) if etag
      end

      # Read the ETag for versions.
      def versions_etag
        read_file(versions_etag_path)&.chomp
      end

      # Size of the versions file (for Range requests).
      def versions_size
        File.exist?(versions_path) ? File.size(versions_path) : 0
      end

      # Read cached info for a gem.
      def info(name)
        read_file(info_path(name))
      end

      # Write info for a gem.
      def write_info(name, data, etag: nil)
        write_file(info_path(name), data)
        write_file(info_etag_path(name), etag) if etag
      end

      # Read the ETag for a gem's info.
      def info_etag(name)
        read_file(info_etag_path(name))&.chomp
      end

      # Check local checksum of info file against remote.
      def info_fresh?(name, remote_checksum)
        return false unless remote_checksum && !remote_checksum.empty?
        data = info(name)
        return false unless data
        local_checksum = Digest::MD5.hexdigest(data)
        local_checksum == remote_checksum
      end

      # Read binary (Marshal) cached parsed info. Returns nil if missing/stale.
      def read_binary_info(name, expected_checksum)
        path = info_binary_path(name)
        return nil unless File.exist?(path)

        cached = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
        if cached.is_a?(Array) && cached.length == 2 && cached[0] == expected_checksum
          cached[1]
        end
      rescue StandardError
        nil
      end

      # Write binary (Marshal) cached parsed info.
      def write_binary_info(name, checksum, parsed_data)
        path = info_binary_path(name)
        FS.mkdir_p(File.dirname(path))
        FS.atomic_write(path, Marshal.dump([checksum, parsed_data]))
      rescue StandardError
        # Non-fatal
      end

      private

      def names_path = File.join(@directory, "names")
      def names_etag_path = File.join(@directory, "names.etag")
      def versions_path = File.join(@directory, "versions")
      def versions_etag_path = File.join(@directory, "versions.etag")

      def info_path(name)
        name = name.to_s
        if /[^a-z0-9_-]/.match?(name)
          File.join(@info_dir, "#{name}-#{hex(name)}")
        else
          File.join(@info_dir, name)
        end
      end

      def info_etag_path(name)
        name = name.to_s
        File.join(@info_etag_dir, "#{name}-#{hex(name)}")
      end

      def info_binary_path(name)
        File.join(@info_binary_dir, "#{name}.bin")
      end

      def hex(str)
        Digest::MD5.hexdigest(str)[0, 12]
      end

      def ensure_dirs
        [@directory, @info_dir, @info_etag_dir, @info_binary_dir].each do |dir|
          FS.mkdir_p(dir)
        end
      end

      def read_file(path)
        return nil unless File.exist?(path)
        File.read(path)
      end

      def write_file(path, data)
        return if data.nil?
        FS.mkdir_p(File.dirname(path))
        FS.atomic_write(path, data)
      end
    end
  end
end
