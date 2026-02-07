# frozen_string_literal: true

require_relative "extension_builder"
require_relative "../platform"

module Scint
  module Installer
    module Planner
      module_function

      # Compare resolved specs against what's already installed.
      # Returns an Array of PlanEntry with action set to one of:
      #   :skip      — already installed in bundle_path
      #   :link      — extracted in global cache, just needs linking
      #   :download  — needs downloading from remote
      #   :build_ext — has native extensions that need compiling
      #
      # Download entries are sorted largest-first so big gems start early,
      # keeping the pipeline saturated while small gems fill in gaps.
      def plan(resolved_specs, bundle_path, cache_layout)
        ruby_dir = ruby_install_dir(bundle_path)
        entries = resolved_specs.map do |spec|
          plan_one(spec, ruby_dir, cache_layout)
        end

        # Keep built-ins first, then downloads (big->small), then the rest.
        builtins, non_builtins = entries.partition { |e| e.action == :builtin }
        downloads, rest = non_builtins.partition { |e| e.action == :download }
        downloads.sort_by! { |e| -(estimated_size(e.spec)) }

        builtins + downloads + rest
      end

      def plan_one(spec, ruby_dir, cache_layout)
        full = cache_layout.full_name(spec)
        gem_path = File.join(ruby_dir, "gems", full)
        spec_path = File.join(ruby_dir, "specifications", "#{full}.gemspec")

        # Built-in gems (scint itself): copy from our own lib tree.
        if spec.name == "scint" && spec.source.to_s.include?("built-in")
          if Dir.exist?(gem_path) && File.exist?(spec_path)
            return PlanEntry.new(spec: spec, action: :skip, cached_path: nil, gem_path: gem_path)
          end

          return PlanEntry.new(spec: spec, action: :builtin, cached_path: nil, gem_path: gem_path)
        end

        # Already installed? Require both gem files and specification.
        if Dir.exist?(gem_path) && File.exist?(spec_path)
          if extension_link_missing?(spec, ruby_dir, cache_layout)
            extracted = cache_layout.extracted_path(spec)
            action = ExtensionBuilder.cached_build_available?(spec, cache_layout) ? :link : :build_ext
            return PlanEntry.new(spec: spec, action: action, cached_path: extracted, gem_path: gem_path)
          end

          return PlanEntry.new(spec: spec, action: :skip, cached_path: nil, gem_path: gem_path)
        end

        # Local path sources are linked directly from their source tree.
        local_source = local_source_path(spec)
        if local_source
          action = ExtensionBuilder.needs_build?(spec, local_source) ? :build_ext : :link
          return PlanEntry.new(spec: spec, action: action, cached_path: local_source, gem_path: gem_path)
        end

        # Extracted in global cache?
        extracted = cache_layout.extracted_path(spec)
        if Dir.exist?(extracted)
          action = needs_ext_build?(spec, cache_layout) ? :build_ext : :link
          return PlanEntry.new(spec: spec, action: action, cached_path: extracted, gem_path: gem_path)
        end

        # Needs downloading
        PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: gem_path)
      end

      def needs_ext_build?(spec, cache_layout)
        extracted = cache_layout.extracted_path(spec)
        return false unless ExtensionBuilder.needs_build?(spec, extracted)

        !ExtensionBuilder.cached_build_available?(spec, cache_layout)
      end

      def extension_link_missing?(spec, ruby_dir, cache_layout)
        extracted = cache_layout.extracted_path(spec)
        return false unless Dir.exist?(extracted)
        return false unless ExtensionBuilder.needs_build?(spec, extracted)

        full = cache_layout.full_name(spec)
        ext_install_dir = File.join(
          ruby_dir,
          "extensions",
          Platform.gem_arch,
          Platform.extension_api_version,
          full,
        )

        !Dir.exist?(ext_install_dir)
      end

      def ruby_install_dir(bundle_path)
        File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      end

      # Rough size estimate for download ordering.
      # If we don't know, use 0 so unknowns sort after large known gems.
      def estimated_size(spec)
        return spec.size if spec.respond_to?(:size) && spec.size
        0
      end

      def local_source_path(spec)
        source =
          if spec.respond_to?(:source)
            spec.source
          else
            spec[:source]
          end
        return nil unless source

        source_str =
          if source.respond_to?(:path)
            source.path.to_s
          elsif source.respond_to?(:uri) && source.class.name.end_with?("::Path")
            source.uri.to_s
          else
            source.to_s
          end
        return nil if source_str.empty?
        return nil if source_str.start_with?("http://", "https://")
        return nil if source_str.end_with?(".git") || source_str.include?(".git/")

        absolute = File.expand_path(source_str, Dir.pwd)
        Dir.exist?(absolute) ? absolute : nil
      end

      private_class_method :plan_one, :needs_ext_build?, :extension_link_missing?,
                           :ruby_install_dir, :estimated_size, :local_source_path
    end
  end
end
