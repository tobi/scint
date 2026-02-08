# frozen_string_literal: true

require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../gem/extractor"
require_relative "../cache/layout"
require_relative "../cache/manifest"
require_relative "../cache/validity"
require_relative "../fs"
require_relative "../errors"
require_relative "../spec_utils"
require_relative "../platform"
require_relative "./promoter"
require_relative "./extension_builder"
require_relative "../source/git"
require_relative "../source/path"

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
          spec = entry.spec
          inbound = @layout.inbound_path(spec)
          assembling = @layout.assembling_path(spec)
          cached = @layout.cached_path(spec)

          if Cache::Validity.cached_valid?(spec, @layout)
            gemspec = load_cached_spec(spec) || read_gemspec_from_extracted(cached, spec)
            already_cached << PreparedGem.new(
              spec: spec,
              extracted_path: cached,
              gemspec: gemspec,
              from_cache: true,
            )
          elsif File.directory?(assembling)
            gemspec = read_gemspec_from_extracted(assembling, spec)
            already_cached << PreparedGem.new(
              spec: spec,
              extracted_path: assembling,
              gemspec: gemspec,
              from_cache: false,
            )
          elsif File.exist?(inbound)
            # Downloaded but not extracted
            already_cached << extract_gem(spec, inbound)
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
        spec = entry.spec
        inbound = @layout.inbound_path(spec)
        assembling = @layout.assembling_path(spec)
        cached = @layout.cached_path(spec)

        if Cache::Validity.cached_valid?(spec, @layout)
          gemspec = load_cached_spec(spec) || read_gemspec_from_extracted(cached, spec)
          return PreparedGem.new(
            spec: spec,
            extracted_path: cached,
            gemspec: gemspec,
            from_cache: true,
          )
        end

        if File.directory?(assembling)
          gemspec = read_gemspec_from_extracted(assembling, spec)
          return PreparedGem.new(
            spec: spec,
            extracted_path: assembling,
            gemspec: gemspec,
            from_cache: false,
          )
        end


        unless File.exist?(inbound)
          uri = gem_download_uri(entry)
          @download_pool.download(uri, inbound)
        end

        extract_gem(spec, inbound)
      end

      private

      def extract_gem(spec, gem_path)
        cached = @layout.cached_path(spec)
        assembling = @layout.assembling_path(spec)

        if Cache::Validity.cached_valid?(spec, @layout)
          gemspec = load_cached_spec(spec) || read_gemspec_from_extracted(cached, spec)
          return PreparedGem.new(spec: spec, extracted_path: cached, gemspec: gemspec, from_cache: true)
        end

        if File.directory?(assembling)
          gemspec = read_gemspec_from_extracted(assembling, spec)
          return PreparedGem.new(spec: spec, extracted_path: assembling, gemspec: gemspec, from_cache: false)
        end

        # Extract to temp dir in assembling, then atomic move
        tmp_dest = "#{assembling}.#{Process.pid}.tmp"
        FileUtils.rm_rf(tmp_dest) if File.exist?(tmp_dest)

        result = @package.extract(gem_path, tmp_dest)
        FS.atomic_move(tmp_dest, assembling)

        if ExtensionBuilder.needs_build?(spec, assembling)
          PreparedGem.new(
            spec: spec,
            extracted_path: assembling,
            gemspec: result[:gemspec],
            from_cache: false,
          )
        else
          promote_assembled(spec, assembling, result[:gemspec])
          PreparedGem.new(
            spec: spec,
            extracted_path: @layout.cached_path(spec),
            gemspec: result[:gemspec],
            from_cache: false,
          )
        end
      end

      def load_cached_spec(spec)
        path = @layout.cached_spec_path(spec)
        return nil unless File.exist?(path)

        data = File.binread(path)
        if data.start_with?("---")
          data.force_encoding("UTF-8") if data.encoding != Encoding::UTF_8
          return Gem::Specification.from_yaml(data)
        end

        Marshal.load(data)
      rescue ArgumentError, TypeError, EOFError, StandardError
        nil
      end

      def cache_spec(spec, gemspec)
        path = @layout.cached_spec_path(spec)
        FS.atomic_write(path, Marshal.dump(gemspec))
      rescue StandardError
        # Non-fatal: cache miss on next load
      end

      def read_gemspec_from_extracted(extracted_dir, spec)
        pattern = File.join(extracted_dir, "*.gemspec")
        candidates = Dir.glob(pattern)
        if candidates.any?
          version = spec.respond_to?(:version) ? spec.version.to_s : nil
          old_version = ENV["VERSION"]
          begin
            ENV["VERSION"] = version if version && !ENV["VERSION"]
            ::Gem::Specification.load(candidates.first)
          rescue SystemExit, StandardError
            nil
          ensure
            ENV["VERSION"] = old_version
          end
        end
      end

      def promote_assembled(spec, assembling_path, gemspec)
        return unless assembling_path && Dir.exist?(assembling_path)

        cached_dir = @layout.cached_path(spec)
        promoter = Promoter.new(root: @layout.root)
        lock_key = "#{Platform.abi_key}-#{@layout.full_name(spec)}"

        promoter.validate_within_root!(@layout.root, assembling_path, label: "assembling")
        promoter.validate_within_root!(@layout.root, cached_dir, label: "cached")

        result = nil
        promoter.with_staging_dir(prefix: "cached") do |staging|
          FS.clone_tree(assembling_path, staging)
          manifest = build_cached_manifest(spec, staging)
          spec_payload = gemspec ? Marshal.dump(gemspec) : nil
          result = promoter.promote_tree(
            staging_path: staging,
            target_path: cached_dir,
            lock_key: lock_key,
          )
          if result == :promoted
            write_cached_metadata(spec, spec_payload, manifest)
          end
        end
        FileUtils.rm_rf(assembling_path) if Dir.exist?(assembling_path)
        result
      rescue StandardError
        FileUtils.rm_rf(cached_dir) if Dir.exist?(cached_dir)
        raise
      end

      def write_cached_metadata(spec, spec_payload, manifest)
        spec_path = @layout.cached_spec_path(spec)
        manifest_path = @layout.cached_manifest_path(spec)
        FS.mkdir_p(File.dirname(spec_path))

        FS.atomic_write(spec_path, spec_payload) if spec_payload
        Cache::Manifest.write(manifest_path, manifest)
      end

      def build_cached_manifest(spec, cached_dir)
        Cache::Manifest.build(
          spec: spec,
          gem_dir: cached_dir,
          abi_key: Platform.abi_key,
          source: manifest_source_for(spec),
          extensions: ExtensionBuilder.needs_build?(spec, cached_dir),
        )
      end

      def manifest_source_for(spec)
        source = spec.source
        if source.is_a?(Source::Git)
          {
            "type" => "git",
            "uri" => source.uri.to_s,
            "revision" => source.revision || source.ref || source.branch || source.tag,
          }.compact
        elsif source.is_a?(Source::Path)
          {
            "type" => "path",
            "path" => File.expand_path(source.path.to_s),
            "uri" => source.path.to_s,
          }
        else
          source_str = source.to_s
          if source_str.start_with?("http://", "https://")
            { "type" => "rubygems", "uri" => source_str }
          elsif source_str.start_with?("/", ".", "~")
            { "type" => "path", "path" => File.expand_path(source_str), "uri" => source_str }
          else
            { "type" => "rubygems", "uri" => source_str }
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
