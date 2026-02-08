# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"
require_relative "../spec_utils"
require_relative "../cache/layout"
require_relative "../cache/validity"
require "pathname"

module Scint
  module Installer
    module Linker
      module_function

      # Link a single extracted gem into .bundle/ruby/{version}/
      # prepared_gem: PreparedGem struct (spec, extracted_path, gemspec, from_cache)
      # bundle_path:  root .bundle/ directory
      def link(prepared_gem, bundle_path)
        link_files(prepared_gem, bundle_path)
        write_binstubs(prepared_gem, bundle_path)
      end

      # Link gem files + gemspec only (no binstubs).
      # This allows binstubs to be scheduled as a separate DAG task.
      def link_files(prepared_gem, bundle_path)
        ruby_dir = Platform.ruby_install_dir(bundle_path)
        link_files_to_ruby_dir(prepared_gem, ruby_dir)
      end

      # Link gem files + gemspec into an explicit ruby gem home directory.
      # This is used for the install-time hermetic build environment.
      def link_files_to_ruby_dir(prepared_gem, ruby_dir)
        spec = prepared_gem.spec
        full_name = SpecUtils.full_name(spec)

        # 1. Link gem files into gems/{full_name}/
        gem_dest = File.join(ruby_dir, "gems", full_name)
        unless Dir.exist?(gem_dest)
          materialize_gem_dir(prepared_gem, gem_dest)
        end

        # 2. Write gemspec into specifications/
        write_gemspec(prepared_gem, ruby_dir, full_name)
      end

      # Write binstubs for one already-linked gem.
      def write_binstubs(prepared_gem, bundle_path)
        ruby_dir = Platform.ruby_install_dir(bundle_path)
        spec = prepared_gem.spec
        full_name = SpecUtils.full_name(spec)
        gem_dest = File.join(ruby_dir, "gems", full_name)
        return unless Dir.exist?(gem_dest)

        # 3. Create binstubs for executables
        write_binstubs_impl(prepared_gem, bundle_path, ruby_dir, gem_dest)
      end

      # Link multiple gems. Thread-safe — each link is independent.
      def link_batch(prepared_gems, bundle_path)
        prepared_gems.each { |pg| link(pg, bundle_path) }
      end

      # --- private helpers ---

      def materialize_gem_dir(prepared_gem, gem_dest)
        manifest = cached_manifest_for(prepared_gem)
        if manifest && manifest["files"].is_a?(Array)
          FS.materialize_from_manifest(prepared_gem.extracted_path, gem_dest, manifest["files"])
        else
          FS.clone_tree(prepared_gem.extracted_path, gem_dest)
        end
      end

      def cached_manifest_for(prepared_gem)
        return nil unless prepared_gem.from_cache

        layout = cache_layout_for(prepared_gem)
        cached_path = layout.cached_path(prepared_gem.spec)
        return nil unless File.expand_path(prepared_gem.extracted_path) == File.expand_path(cached_path)

        manifest = Cache::Validity.read_manifest(layout.cached_manifest_path(prepared_gem.spec))
        return nil unless manifest
        return nil unless Cache::Validity.manifest_matches?(manifest, prepared_gem.spec, Platform.abi_key, layout)

        manifest
      rescue StandardError
        nil
      end

      def cache_layout_for(prepared_gem)
        extracted = File.expand_path(prepared_gem.extracted_path)
        abi_dir = File.dirname(extracted)
        cached_dir = File.dirname(abi_dir)
        root = File.dirname(cached_dir)

        if File.basename(abi_dir) == Platform.abi_key && File.basename(cached_dir) == "cached"
          Cache::Layout.new(root: root)
        else
          Cache::Layout.new
        end
      end

      def write_gemspec(prepared_gem, ruby_dir, full_name)
        spec_dir = File.join(ruby_dir, "specifications")
        FS.mkdir_p(spec_dir)
        spec_path = File.join(spec_dir, "#{full_name}.gemspec")
        return if File.exist?(spec_path)

        content = if prepared_gem.gemspec.is_a?(String)
                    prepared_gem.gemspec
                  elsif prepared_gem.gemspec.respond_to?(:to_ruby)
                    augment_executable_metadata(prepared_gem.gemspec, prepared_gem.extracted_path).to_ruby
                  else
                    minimal_gemspec(prepared_gem.spec, full_name)
                  end

        FS.atomic_write(spec_path, content)
      end

      def write_binstubs_impl(prepared_gem, bundle_path, ruby_dir, gem_dir)
        # Look for executables declared in the gemspec
        executables = extract_executables(prepared_gem, gem_dir)
        return if executables.empty?

        ruby_bin_dir = File.join(ruby_dir, "bin")
        bundle_bin_dir = File.join(bundle_path, "bin")
        FS.mkdir_p(ruby_bin_dir)
        FS.mkdir_p(bundle_bin_dir)

        executables.each do |exe_name|
          write_ruby_bin_stub(prepared_gem, ruby_bin_dir, exe_name)
          write_bundle_bin_wrapper(bundle_path, ruby_bin_dir, bundle_bin_dir, exe_name)
        end
      end

      def write_ruby_bin_stub(prepared_gem, ruby_bin_dir, exe_name)
        binstub_path = File.join(ruby_bin_dir, exe_name)
        return if File.exist?(binstub_path)

        spec = prepared_gem.spec
        content = <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true
          #
          # This file was generated by scint for #{SpecUtils.full_name(spec)}
          #
          gem "#{spec.name}", "#{spec.version}"
          load Gem.bin_path("#{spec.name}", "#{exe_name}", "#{spec.version}")
        RUBY

        FS.atomic_write(binstub_path, content)
        File.chmod(0o755, binstub_path)
      end

      def write_bundle_bin_wrapper(bundle_path, ruby_bin_dir, bundle_bin_dir, exe_name)
        wrapper_path = File.join(bundle_bin_dir, exe_name)
        return if File.exist?(wrapper_path)

        target = File.join(ruby_bin_dir, exe_name)
        relative_target = Pathname.new(target).relative_path_from(Pathname.new(bundle_bin_dir)).to_s
        content = <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true
          exec(File.expand_path("#{relative_target}", __dir__), *ARGV)
        RUBY

        FS.atomic_write(wrapper_path, content)
        File.chmod(0o755, wrapper_path)
      end

      def extract_executables(prepared_gem, gem_dir)
        gemspec = prepared_gem.gemspec
        executables = if gemspec.respond_to?(:executables)
          Array(gemspec.executables)
        elsif gemspec.is_a?(Hash) && gemspec[:executables]
          Array(gemspec[:executables])
        else
          []
        end

        if executables.empty?
          executables = detect_executables_from_files(gem_dir)
        end

        executables.map(&:to_s).reject(&:empty?).uniq
      end

      def detect_executables_from_files(gem_dir)
        names = []
        %w[exe bin].each do |subdir|
          dir = File.join(gem_dir, subdir)
          next unless Dir.exist?(dir)

          Dir.children(dir).each do |entry|
            next if entry.start_with?(".")
            path = File.join(dir, entry)
            names << entry if File.file?(path)
          end
        end
        names
      end

      def augment_executable_metadata(gemspec, gem_dir)
        detected = detect_executables_from_files(gem_dir)
        return gemspec if detected.empty?

        executables = Array(gemspec.executables).map(&:to_s).reject(&:empty?)
        bindir = gemspec.respond_to?(:bindir) ? gemspec.bindir.to_s : ""

        selected = executables.empty? ? detected : executables
        inferred_bindir = infer_bindir(gem_dir, selected, bindir)
        needs_execs = executables.empty?
        needs_bindir = !inferred_bindir.nil? && inferred_bindir != bindir
        return gemspec unless needs_execs || needs_bindir

        patched = gemspec.dup
        patched.executables = selected if needs_execs
        patched.bindir = inferred_bindir if needs_bindir
        patched
      end

      def infer_bindir(gem_dir, executables, current_bindir)
        %w[exe bin].each do |dir|
          next unless executables.all? { |exe| File.file?(File.join(gem_dir, dir, exe)) }
          return dir
        end

        current_bindir unless current_bindir.empty?
      end

      def minimal_gemspec(spec, full_name)
        <<~RUBY
          # frozen_string_literal: true
          Gem::Specification.new do |s|
            s.name = #{spec.name.inspect}
            s.version = #{spec.version.to_s.inspect}
            s.platform = #{SpecUtils.platform_str(spec).inspect}
            s.authors = ["scint"]
            s.summary = "Installed by scint"
          end
        RUBY
      end

      private_class_method :materialize_gem_dir, :cached_manifest_for, :cache_layout_for,
                           :write_gemspec, :write_binstubs_impl, :write_ruby_bin_stub,
                           :write_bundle_bin_wrapper, :extract_executables,
                           :detect_executables_from_files, :augment_executable_metadata, :infer_bindir,
                           :minimal_gemspec
    end
  end
end
