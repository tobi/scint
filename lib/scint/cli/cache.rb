# frozen_string_literal: true

require "fileutils"
require_relative "../cache/layout"
require_relative "../fs"

module Scint
  module CLI
    class Cache
      def initialize(argv = [])
        @argv = argv.dup
      end

      def run
        subcommand = @argv.shift || "help"

        case subcommand
        when "clean", "clear"
          clean
        when "dir", "path"
          dir
        when "size"
          size
        when "help", "-h", "--help"
          help
          0
        else
          $stderr.puts "Unknown cache subcommand: #{subcommand}"
          $stderr.puts "Run 'scint cache help' for usage."
          1
        end
      end

      private

      def cache_root
        @cache_root ||= Scint::Cache::Layout.new.root
      end

      # scint cache clean [package...]
      # With no args, clear everything. With args, clear only matching entries.
      def clean
        packages = @argv.dup

        unless Dir.exist?(cache_root)
          $stdout.puts "No cache to clear (#{cache_root} does not exist)"
          return 0
        end

        if packages.empty?
          removed = clear_all
          $stdout.puts "Cleared #{removed} entries from #{cache_root}"
        else
          removed = clear_packages(packages)
          $stdout.puts "Removed #{removed} entries matching: #{packages.join(", ")}"
        end

        0
      end

      # scint cache dir
      def dir
        $stdout.puts cache_root
        0
      end

      # scint cache size
      def size
        unless Dir.exist?(cache_root)
          $stdout.puts "0 B (cache is empty)"
          return 0
        end

        total_bytes = 0
        total_files = 0
        subdirs = {}

        Dir.children(cache_root).sort.each do |subdir|
          subdir_path = File.join(cache_root, subdir)
          next unless File.directory?(subdir_path)

          bytes = 0
          files = 0
          Dir.glob("**/*", base: subdir_path).each do |rel|
            full = File.join(subdir_path, rel)
            next unless File.file?(full)
            bytes += File.size(full)
            files += 1
          end

          subdirs[subdir] = { bytes: bytes, files: files }
          total_bytes += bytes
          total_files += files
        end

        # Print breakdown with aligned columns
        all_rows = subdirs.map { |name, info| [name, info[:bytes], info[:files]] }
        all_rows << ["total", total_bytes, total_files]

        nw = all_rows.map { |r| r[0].length }.max
        sw = all_rows.map { |r| format_size(r[1]).length }.max
        fw = all_rows.map { |r| "#{r[2]} files".length }.max

        all_rows.each do |name, bytes, files|
          $stdout.printf "  %-*s  %*s  %*s\n", nw, name, sw, format_size(bytes), fw, "#{files} files"
        end

        0
      end

      def help
        $stdout.puts <<~HELP
          Manage scint's cache

          Usage: scint cache <COMMAND>

          Commands:
            clean  Clear the cache, removing all entries or those linked to specific packages
            dir    Show the cache directory
            size   Show the cache size
        HELP
      end

      # -- Implementation -------------------------------------------------------

      def clear_all
        entries = Dir.children(cache_root)
        entries.each do |entry|
          FileUtils.rm_rf(File.join(cache_root, entry))
        end
        entries.size
      end

      def clear_packages(packages)
        removed = 0
        %w[inbound extracted ext].each do |subdir|
          subdir_path = File.join(cache_root, subdir)
          next unless Dir.exist?(subdir_path)

          Dir.children(subdir_path).each do |entry|
            if packages.any? { |pkg| entry.start_with?(pkg) }
              FileUtils.rm_rf(File.join(subdir_path, entry))
              removed += 1
            end
          end
        end
        removed
      end

      def format_size(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KiB"
        elsif bytes < 1024 * 1024 * 1024
          "#{(bytes / (1024.0 * 1024)).round(1)} MiB"
        else
          "#{(bytes / (1024.0 * 1024 * 1024)).round(1)} GiB"
        end
      end
    end
  end
end
