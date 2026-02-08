# frozen_string_literal: true

require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../gem/extractor"
require_relative "../cache/layout"
require_relative "../fs"
require_relative "../errors"
require_relative "../spec_utils"
require_relative "./promoter"

module Scint
  module Installer
    # Data structures used by the preparer.
    PlanEntry = Struct.new(:spec, :action, :cached_path, :gem_path, keyword_init: true)
    PreparedGem = Struct.new(:spec, :extracted_path, :gemspec, :from_cache, keyword_init: true)

    class Preparer
      attr_reader :results

      # scheduler: optional Scint::Scheduler for enqueuing jobs
      # layout: Cache::Layout instance
      # on_progress: optional callback proc
      def initialize(layout:, scheduler: nil, on_progress: nil)
        @layout = layout
        @scheduler = scheduler
        @on_progress = on_progress
        @download_pool = Downloader::Pool.new(on_progress: on_progress)
        @package = GemPkg::Package.new
        @results = []
        @mutex = Thread::Mutex.new
      end

      # Prepare all plan entries: download + extract as needed.
      # Returns array of PreparedGem.
      def prepare(entries)
        # Sort by estimated size descending (larger gems first for better parallelism).
        # Use version as rough proxy for size if no other info available.
        sorted = entries.sort_by do |e|
          s = e.spec
          name = s.respond_to?(:name) ? s.name : s[:name]
          -(name.length) # Longer names tend to be larger packages
        end

        to_download = []
        already_cached = []

        sorted.each do |entry|
          inbound = @layout.inbound_path(entry.spec)
          extracted = @layout.extracted_path(entry.spec)

          if File.directory?(extracted)
            # Already extracted -- load gemspec from cache or re-read
            gemspec = load_cached_spec(entry.spec) || read_gemspec_from_extracted(extracted, entry.spec)
            already_cached << PreparedGem.new(
              spec: entry.spec,
              extracted_path: extracted,
              gemspec: gemspec,
              from_cache: true,
            )
          elsif File.exist?(inbound)
            # Downloaded but not extracted
            already_cached << extract_gem(entry.spec, inbound)
          else
            # Need to download
            to_download << entry
          end
        end

        begin
          # Batch download everything that's missing
          if to_download.any?
            download_items = to_download.map do |entry|
              spec = entry.spec
              source_uri = gem_download_uri(entry)

              {
                uri: source_uri,
                dest: @layout.inbound_path(spec),
                spec: spec,
                checksum: nil,
              }
            end

            download_results = @download_pool.download_batch(download_items)

            download_results.each do |dr|
              if dr[:error]
                name = dr[:spec].respond_to?(:name) ? dr[:spec].name : dr[:spec][:name]
                raise InstallError, "Failed to download #{name}: #{dr[:error].message}"
              end

              already_cached << extract_gem(dr[:spec], dr[:path])
            end
          end
        ensure
          @download_pool.close
        end

        @mutex.synchronize do
          @results = already_cached
        end

        already_cached
      end

      # Prepare a single entry (for use with scheduler).
      def prepare_one(entry)
        inbound = @layout.inbound_path(entry.spec)
        extracted = @layout.extracted_path(entry.spec)

        if File.directory?(extracted)
          gemspec = load_cached_spec(entry.spec) || read_gemspec_from_extracted(extracted, entry.spec)
          return PreparedGem.new(
            spec: entry.spec,
            extracted_path: extracted,
            gemspec: gemspec,
            from_cache: true,
          )
        end

        unless File.exist?(inbound)
          uri = gem_download_uri(entry)
          @download_pool.download(uri, inbound)
        end

        extract_gem(entry.spec, inbound)
      end

      private

      def extract_gem(spec, gem_path)
        dest = @layout.extracted_path(spec)

        if File.directory?(dest)
          gemspec = load_cached_spec(spec) || read_gemspec_from_extracted(dest, spec)
          return PreparedGem.new(spec: spec, extracted_path: dest, gemspec: gemspec, from_cache: true)
        end

        # Extract to temp dir, then atomic move
        tmp_dest = "#{dest}.#{Process.pid}.tmp"
        FileUtils.rm_rf(tmp_dest) if File.exist?(tmp_dest)

        result = @package.extract(gem_path, tmp_dest)
        FS.atomic_move(tmp_dest, dest)

        # Cache the gemspec as Marshal for fast future loads
        cache_spec(spec, result[:gemspec])

        PreparedGem.new(
          spec: spec,
          extracted_path: dest,
          gemspec: result[:gemspec],
          from_cache: false,
        )
      end

      def load_cached_spec(spec)
        path = @layout.spec_cache_path(spec)
        return nil unless File.exist?(path)
        Marshal.load(File.binread(path))
      rescue ArgumentError, TypeError, EOFError
        nil
      end

      def cache_spec(spec, gemspec)
        path = @layout.spec_cache_path(spec)
        FS.atomic_write(path, Marshal.dump(gemspec))
      rescue StandardError
        # Non-fatal: cache miss on next load
      end

      def read_gemspec_from_extracted(extracted_dir, spec)
        pattern = File.join(extracted_dir, "*.gemspec")
        candidates = Dir.glob(pattern)
        if candidates.any?
          begin
            ::Gem::Specification.load(candidates.first)
          rescue StandardError
            nil
          end
        end
      end

      def gem_download_uri(entry)
        spec = entry.spec
        filename = "#{SpecUtils.full_name(spec)}.gem"

        # Use cached_path if provided, otherwise construct from source
        if entry.cached_path
          entry.cached_path
        elsif entry.gem_path
          entry.gem_path
        else
          # Default to rubygems.org
          "https://rubygems.org/gems/#{filename}"
        end
      end
    end
  end
end
