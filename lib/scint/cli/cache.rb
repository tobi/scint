# frozen_string_literal: true

require "fileutils"
require_relative "../cache/layout"
require_relative "../cache/prewarm"
require_relative "../credentials"
require_relative "../gemfile/dependency"
require_relative "../gemfile/parser"
require_relative "../lockfile/parser"
require_relative "install"
require_relative "../fs"
require_relative "../spec_utils"

module Scint
  module CLI
    class Cache
      def initialize(argv = [])
        @argv = argv.dup
      end

      def run
        subcommand = @argv.shift || "help"

        case subcommand
        when "add"
          add
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
            add    Prewarm cache from gem names and/or Gemfile/Gemfile.lock
            clean  Clear the cache, removing all entries or those linked to specific packages
            dir    Show the cache directory
            size   Show the cache size
        HELP
      end

      # scint cache add GEM [GEM...]
      # scint cache add --lockfile Gemfile.lock
      # scint cache add --gemfile Gemfile
      def add
        options = parse_add_options
        if options[:gems].empty? && !options[:lockfile] && !options[:gemfile]
          $stderr.puts "Usage: scint cache add GEM [GEM...] [--lockfile FILE] [--gemfile FILE] [--jobs N] [--force]"
          return 1
        end

        specs = collect_specs_for_add(options)
        prewarm = Scint::Cache::Prewarm.new(
          cache_layout: Scint::Cache::Layout.new,
          jobs: options[:jobs],
          credentials: options[:credentials],
          force: options[:force],
        )
        result = prewarm.run(specs)

        if result[:failed] > 0
          $stderr.puts "Cache prewarm failed for #{result[:failed]} gem(s):"
          result[:failures].each do |failure|
            spec = failure[:spec]
            $stderr.puts "  #{spec.name}: #{failure[:error].message}"
          end
          $stdout.puts "Cache add: #{result[:warmed]} warmed, #{result[:skipped]} skipped, #{result[:ignored]} ignored."
          return 1
        end

        $stdout.puts "Cache add complete: #{result[:warmed]} warmed, #{result[:skipped]} skipped, #{result[:ignored]} ignored."
        0
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

        packages.each do |pkg|
          # inbound gems
          Dir.glob(File.join(cache_root, "inbound", "gems", "#{pkg}-*.gem")).each do |path|
            FileUtils.rm_rf(path)
            removed += 1
          end

          # assembling + cached (per-ABI)
          %w[assembling cached].each do |subdir|
            Dir.glob(File.join(cache_root, subdir, "*", "#{pkg}-*")) do |path|
              FileUtils.rm_rf(path)
              removed += 1
            end
            Dir.glob(File.join(cache_root, subdir, "*", "#{pkg}-*.spec.marshal")) do |path|
              FileUtils.rm_rf(path)
              removed += 1
            end
            Dir.glob(File.join(cache_root, subdir, "*", "#{pkg}-*.manifest")) do |path|
              FileUtils.rm_rf(path)
              removed += 1
            end
          end

          # legacy directories (extracted/ext)
          Dir.glob(File.join(cache_root, "extracted", "#{pkg}-*")) do |path|
            FileUtils.rm_rf(path)
            removed += 1
          end
          Dir.glob(File.join(cache_root, "extracted", "#{pkg}-*.spec.marshal")) do |path|
            FileUtils.rm_rf(path)
            removed += 1
          end
          Dir.glob(File.join(cache_root, "ext", "*", "#{pkg}-*")) do |path|
            FileUtils.rm_rf(path)
            removed += 1
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

      def parse_add_options
        opts = {
          gems: [],
          lockfile: nil,
          gemfile: nil,
          jobs: nil,
          force: false,
          version: nil,
          source: "https://rubygems.org",
        }

        i = 0
        while i < @argv.length
          token = @argv[i]
          case token
          when "--lockfile"
            opts[:lockfile] = @argv[i + 1]
            i += 2
          when "--gemfile"
            opts[:gemfile] = @argv[i + 1]
            i += 2
          when "--jobs", "-j"
            opts[:jobs] = @argv[i + 1]&.to_i
            i += 2
          when "--force", "-f"
            opts[:force] = true
            i += 1
          when "--version"
            opts[:version] = @argv[i + 1]
            i += 2
          when "--source"
            opts[:source] = @argv[i + 1]
            i += 2
          else
            if token.start_with?("-")
              raise CacheError, "Unknown option for cache add: #{token}"
            end
            opts[:gems] << token
            i += 1
          end
        end

        opts[:credentials] = Credentials.new
        opts
      end

      def collect_specs_for_add(options)
        specs = []
        install = CLI::Install.new([])
        install.instance_variable_set(:@credentials, options[:credentials])

        if options[:lockfile]
          lockfile = Scint::Lockfile::Parser.parse(options[:lockfile])
          options[:credentials].register_lockfile_sources(lockfile.sources)
          specs.concat(install.send(:lockfile_to_resolved, lockfile))
        end

        if options[:gemfile]
          specs.concat(resolve_from_gemfile(install, options[:gemfile], options[:credentials]))
        end

        unless options[:gems].empty?
          specs.concat(resolve_from_names(install, options))
        end

        dedupe_specs(specs)
      end

      def resolve_from_gemfile(install, gemfile_path, credentials)
        gemfile = Scint::Gemfile::Parser.parse(gemfile_path)
        credentials.register_sources(gemfile.sources)
        credentials.register_dependencies(gemfile.dependencies)

        lockfile_path = File.join(File.dirname(File.expand_path(gemfile_path)), "Gemfile.lock")
        lockfile = File.exist?(lockfile_path) ? Scint::Lockfile::Parser.parse(lockfile_path) : nil
        credentials.register_lockfile_sources(lockfile.sources) if lockfile

        if lockfile && install.send(:lockfile_current?, gemfile, lockfile)
          install.send(:lockfile_to_resolved, lockfile)
        else
          install.send(:resolve, gemfile, lockfile, Scint::Cache::Layout.new)
        end
      end

      def resolve_from_names(install, options)
        deps = options[:gems].map do |name|
          source_options = {}
          source_options[:source] = options[:source] if options[:source]
          reqs = options[:version] ? [options[:version]] : [">= 0"]
          Scint::Gemfile::Dependency.new(name, version_reqs: reqs, source_options: source_options)
        end

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: deps,
          sources: [{ type: :rubygems, uri: options[:source] }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:resolve, gemfile, nil, Scint::Cache::Layout.new)
      end

      def dedupe_specs(specs)
        seen = {}
        specs.each do |spec|
          key = SpecUtils.full_key(spec)
          seen[key] ||= spec
        end
        seen.values
      end
    end
  end
end
