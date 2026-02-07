# frozen_string_literal: true

require "fileutils"
require_relative "../cache/layout"
require_relative "../fs"

module Scint
  module CLI
    class Cache
      EMPTY_MSG = "(cache is empty)"

      def initialize(argv = [])
        @argv = argv.dup
      end

      def run
        subcommand = @argv.shift || "list"

        case subcommand
        when "list", "ls"
          list_cache
        when "clear", "clean"
          clear_cache
        when "dir", "path"
          show_cache_dir
        when "help", "-h", "--help"
          print_help
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

      def show_cache_dir
        $stdout.puts cache_root
        0
      end

      def list_cache
        unless Dir.exist?(cache_root)
          $stdout.puts EMPTY_MSG
          return 0
        end

        entries = Dir.children(cache_root).sort
        if entries.empty?
          $stdout.puts EMPTY_MSG
          return 0
        end

        entries.each do |entry|
          path = File.join(cache_root, entry)
          if File.directory?(path)
            count = Dir.glob("**/*", File::FNM_DOTMATCH, base: path)
              .count { |rel| rel != "." && rel != ".." && File.file?(File.join(path, rel)) }
            $stdout.puts "#{entry}\t#{count} files\t#{path}"
          else
            $stdout.puts "#{entry}\t#{File.size(path)} bytes\t#{path}"
          end
        end

        0
      end

      def clear_cache
        if Dir.exist?(cache_root)
          Dir.children(cache_root).each do |entry|
            FileUtils.rm_rf(File.join(cache_root, entry))
          end
        else
          FS.mkdir_p(cache_root)
        end

        $stdout.puts "Cleared cache: #{cache_root}"
        0
      end

      def print_help
        $stdout.puts <<~HELP
          Usage: scint cache SUBCOMMAND

          Subcommands:
            list   List cache contents
            clear  Remove all cached files
            dir    Print cache directory path
        HELP
      end
    end
  end
end
