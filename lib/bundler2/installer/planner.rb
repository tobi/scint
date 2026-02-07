# frozen_string_literal: true

module Bundler2
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

        # Stable partition: downloads first (big→small), then everything else
        downloads, rest = entries.partition { |e| e.action == :download }
        downloads.sort_by! { |e| -(estimated_size(e.spec)) }

        downloads + rest
      end

      def plan_one(spec, ruby_dir, cache_layout)
        full = cache_layout.full_name(spec)
        gem_path = File.join(ruby_dir, "gems", full)

        # Already installed?
        if Dir.exist?(gem_path)
          return PlanEntry.new(spec: spec, action: :skip, cached_path: nil, gem_path: gem_path)
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
        return false unless spec.respond_to?(:has_extensions) && spec.has_extensions

        ext_dir = cache_layout.ext_path(spec)
        !Dir.exist?(ext_dir)
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

      private_class_method :plan_one, :needs_ext_build?, :ruby_install_dir, :estimated_size
    end
  end
end
