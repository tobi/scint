# frozen_string_literal: true

require "rubygems/package"
require "zlib"
require "fileutils"
require_relative "../fs"

module Bundler2
  module GemPkg
    class Extractor
      # Extract data.tar.gz contents into dest_dir.
      # Primary: shell out to system tar for speed.
      # Fallback: pure Ruby extraction.
      def extract(data_tar_gz_path, dest_dir)
        FS.mkdir_p(dest_dir)

        if system_tar_available?
          extract_with_system_tar(data_tar_gz_path, dest_dir)
        else
          extract_with_ruby(data_tar_gz_path, dest_dir)
        end

        dest_dir
      end

      private

      def system_tar_available?
        @system_tar_available = system("tar", "--version", [:out, :err] => File::NULL) if @system_tar_available.nil?
        @system_tar_available
      rescue Errno::ENOENT
        @system_tar_available = false
      end

      def extract_with_system_tar(data_tar_gz_path, dest_dir)
        result = system("tar", "xzf", data_tar_gz_path, "-C", dest_dir)
        return if result

        # If system tar fails, fall back to Ruby
        extract_with_ruby(data_tar_gz_path, dest_dir)
      end

      def extract_with_ruby(data_tar_gz_path, dest_dir)
        File.open(data_tar_gz_path, "rb") do |file|
          gz = Zlib::GzipReader.new(file)
          tar = ::Gem::Package::TarReader.new(gz)

          tar.each do |entry|
            dest_path = File.join(dest_dir, entry.full_name)

            # Security: prevent path traversal
            unless safe_path?(dest_dir, dest_path)
              next
            end

            if entry.directory?
              FS.mkdir_p(dest_path)
            elsif entry.symlink?
              # Only follow symlinks that stay inside dest_dir
              link_target = File.expand_path(entry.header.linkname, File.dirname(dest_path))
              if safe_path?(dest_dir, link_target)
                FS.mkdir_p(File.dirname(dest_path))
                File.symlink(entry.header.linkname, dest_path)
              end
            elsif entry.file?
              FS.mkdir_p(File.dirname(dest_path))
              File.open(dest_path, "wb") do |f|
                while (chunk = entry.read(16384))
                  f.write(chunk)
                end
              end
              File.chmod(entry.header.mode, dest_path) if entry.header.mode
            end
          end
        end
      end

      # Ensure dest_path is inside base_dir (prevent directory traversal).
      def safe_path?(base_dir, dest_path)
        expanded = File.expand_path(dest_path)
        expanded_base = File.expand_path(base_dir)
        expanded.start_with?("#{expanded_base}/") || expanded == expanded_base
      end
    end
  end
end
