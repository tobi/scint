# frozen_string_literal: true

require_relative "extension_builder"
require_relative "../platform"
require_relative "../cache/validity"

module Scint
  module Installer
    module Planner
      module_function
      PATH_GLOB_DEFAULT = "{,*,*/*}.gemspec"

      # Compare resolved specs against what's already installed.
      # Returns an Array of PlanEntry with action set to one of:
      #   :skip      — already installed in bundle_path
      #   :link      — cached in global cache, just needs linking
      #   :download  — needs downloading from remote
      #   :build_ext — has native extensions that need compiling
      #
      # Download entries are sorted largest-first so big gems start early,
      # keeping the pipeline saturated while small gems fill in gaps.
      def plan(resolved_specs, bundle_path, cache_layout, telemetry: nil)
        ruby_dir = Platform.ruby_install_dir(bundle_path)
        entries = resolved_specs.map do |spec|
          plan_one(spec, ruby_dir, cache_layout, telemetry: telemetry)
        end

        # Keep built-ins first, then downloads (big->small), then the rest.
        builtins, non_builtins = entries.partition { |e| e.action == :builtin }
        downloads, rest = non_builtins.partition { |e| e.action == :download }
        downloads.sort_by! { |e| -(estimated_size(e.spec)) }

        builtins + downloads + rest
      end

      def plan_one(spec, ruby_dir, cache_layout, telemetry: nil)
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
          cache_source = Cache::Validity.source_path_for(spec, cache_layout, telemetry: telemetry)
          if extension_link_missing?(spec, ruby_dir, cache_layout, cache_source)
            action = ExtensionBuilder.cached_build_available?(spec, cache_layout) ? :link : :build_ext
            return PlanEntry.new(spec: spec, action: action, cached_path: cache_source, gem_path: gem_path) if cache_source

            return PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: gem_path)
          end

          return PlanEntry.new(spec: spec, action: :skip, cached_path: nil, gem_path: gem_path)
        end

        # Local path sources are linked directly from their source tree.
        local_source = local_source_path(spec)
        if local_source
          action = ExtensionBuilder.needs_build?(spec, local_source) ? :build_ext : :link
          return PlanEntry.new(spec: spec, action: action, cached_path: local_source, gem_path: gem_path)
        end

        cache_source = Cache::Validity.source_path_for(spec, cache_layout, telemetry: telemetry)
        if cache_source
          action = needs_ext_build?(spec, cache_layout, cache_source) ? :build_ext : :link
          return PlanEntry.new(spec: spec, action: action, cached_path: cache_source, gem_path: gem_path)
        end

        # Needs downloading
        PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: gem_path)
      end

      def needs_ext_build?(spec, cache_layout, source_dir)
        return false unless source_dir
        return false unless ExtensionBuilder.needs_build?(spec, source_dir)

        !ExtensionBuilder.cached_build_available?(spec, cache_layout)
      end

      def extension_link_missing?(spec, ruby_dir, cache_layout, source_dir)
        return false unless source_dir
        return false unless ExtensionBuilder.needs_build?(spec, source_dir)

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
        return nil unless Dir.exist?(absolute)

        spec_name =
          if spec.respond_to?(:name)
            spec.name.to_s
          else
            spec[:name].to_s
          end
        return absolute if spec_name.empty?
        return absolute if File.exist?(File.join(absolute, "#{spec_name}.gemspec"))

        glob =
          if source.respond_to?(:glob) && !source.glob.to_s.empty?
            source.glob.to_s
          else
            PATH_GLOB_DEFAULT
          end

        Dir.glob(File.join(absolute, glob)).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == spec_name
        end

        Dir.glob(File.join(absolute, "**", "*.gemspec")).each do |path|
          return File.dirname(path) if File.basename(path, ".gemspec") == spec_name
        end

        absolute
      end

      private_class_method :plan_one, :needs_ext_build?, :extension_link_missing?,
                           :estimated_size, :local_source_path
    end
  end
end
