# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "../installer/extension_builder"

module Scint
  module Cache
    class Telemetry
      def initialize
        @counts = Hash.new(0)
        @mutex = Thread::Mutex.new
      end

      def increment(key, by = 1)
        @mutex.synchronize do
          @counts[key] += by
        end
      end

      def counts
        @mutex.synchronize { @counts.dup }
      end

      def warn_if_needed(cache_root:, io: $stderr)
        snapshot = counts
        return if snapshot.empty?

        header = "Warning: legacy cache fallback used in #{cache_root}"
        io.puts "#{YELLOW}#{header}#{RESET}"
        snapshot.sort.each do |key, value|
          io.puts "  #{key}=#{value}"
        end
      end
    end

    module Validity
      module_function

      SUPPORTED_MANIFEST_VERSION = 1

      def cached_valid?(spec, layout, abi_key: Platform.abi_key, telemetry: nil)
        cached_dir = layout.cached_path(spec, abi_key)
        spec_path = layout.cached_spec_path(spec, abi_key)
        manifest_path = layout.cached_manifest_path(spec, abi_key)

        return false unless Dir.exist?(cached_dir)
        return false unless File.exist?(spec_path)

        manifest = read_manifest(manifest_path, telemetry: telemetry)
        if manifest
          return false unless manifest_matches?(manifest, spec, abi_key, layout)
        else
          return false unless legacy_spec_loadable?(spec_path)
        end

        true
      end

      def source_path_for(spec, layout, abi_key: Platform.abi_key, telemetry: nil, allow_legacy: false)
        cached_dir = layout.cached_path(spec, abi_key)
        return cached_dir if cached_valid?(spec, layout, abi_key: abi_key, telemetry: telemetry)

        return nil unless allow_legacy

        legacy = layout.extracted_path(spec)
        return nil unless legacy_extracted_valid?(spec, legacy, layout)

        telemetry&.increment("cache.legacy.extracted")
        legacy
      end

      def legacy_extracted_valid?(spec, extracted_dir, layout)
        return false unless Dir.exist?(extracted_dir)

        legacy_spec_path = layout.spec_cache_path(spec)
        return true if File.exist?(legacy_spec_path)

        return true if Dir.glob(File.join(extracted_dir, "*.gemspec")).any?

        true
      rescue StandardError
        false
      end

      def read_manifest(path, telemetry: nil)
        unless File.exist?(path)
          telemetry&.increment("cache.manifest.missing")
          return nil
        end

        data = JSON.parse(File.read(path))
        return nil unless data.is_a?(Hash)

        version = data["version"]
        return data if version == SUPPORTED_MANIFEST_VERSION

        telemetry&.increment("cache.manifest.unsupported")
        nil
      rescue StandardError
        telemetry&.increment("cache.manifest.unsupported")
        nil
      end

      def manifest_matches?(manifest, spec, abi_key, layout)
        manifest["full_name"] == layout.full_name(spec) && manifest["abi"] == abi_key
      rescue StandardError
        false
      end

      def legacy_spec_loadable?(path)
        Marshal.load(File.binread(path))
        true
      rescue StandardError
        false
      end

      def extensions_required?(spec, cached_dir)
        Installer::ExtensionBuilder.needs_build?(spec, cached_dir)
      rescue StandardError
        false
      end

      def extension_build_complete?(spec, layout, abi_key)
        marker = File.join(layout.cached_path(spec, abi_key), Installer::ExtensionBuilder::BUILD_MARKER)
        File.exist?(marker)
      rescue StandardError
        false
      end
    end
  end
end
