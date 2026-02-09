# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"
require "zlib"
require "stringio"
require "rubygems/package"

require_relative "../spec_utils"
require_relative "../platform"
require_relative "../source/path"
require_relative "../source/git"
require_relative "layout"

module Scint
  module Cache
    # Export gem sources from the scint cache into clean, platform-neutral
    # directories suitable for hermetic builds (e.g. Nix derivations).
    #
    # High-level usage:
    #
    #   bundle = Scint::Bundle.new("/path/to/project")
    #   gems   = Scint::Cache::Export.from_lockfile(bundle)
    #
    #   gems.each do |gem|
    #     gem.name             # => "nokogiri"
    #     gem.version          # => "1.19.0"
    #     gem.full_name        # => "nokogiri-1.19.0"
    #     gem.dependencies     # => ["racc", "mini_portile2"]
    #     gem.has_extensions   # => true
    #     gem.require_paths    # => ["lib"]
    #     gem.executables      # => []
    #     gem.bindir           # => "exe"
    #     gem.platform_gem?    # => true   (lockfile had platform-specific entry)
    #     gem.git_source?      # => false
    #     gem.git_checkout_dir # => nil    (or "rails-60d92e4e7dfe" for git gems)
    #
    #     gem.export("/tmp/out/nokogiri-1.19.0/source")
    #     # => copies source, strips prebuilt .so/.bundle/.dylib
    #   end
    #
    module Export
      class ExportedGem
        attr_reader :name, :version, :dependencies, :has_extensions,
                    :require_paths, :executables, :bindir,
                    :git_checkout_dir, :source_subdir,
                    :platform_variants

        def initialize(attrs)
          @name            = attrs[:name]
          @version         = attrs[:version]
          @dependencies    = attrs[:dependencies] || []
          @has_extensions  = attrs[:has_extensions] || false
          @require_paths   = attrs[:require_paths] || ["lib"]
          @executables     = attrs[:executables] || []
          @bindir          = attrs[:bindir] || "exe"
          @is_platform_gem = attrs[:is_platform_gem] || false
          @git_checkout_dir = attrs[:git_checkout_dir]
          @source_subdir   = attrs[:source_subdir]
          @cached_dir      = attrs[:cached_dir]
          @platform_variants = attrs[:platform_variants] || []
          @has_exported    = false
        end

        def full_name
          "#{@name}-#{@version}"
        end

        def platform_gem?
          @is_platform_gem
        end

        def git_source?
          !@git_checkout_dir.nil?
        end

        # Export source to target directory.
        # Copies from scint cache, strips prebuilt native extensions.
        # No-op if target already exists (unless force: true).
        #
        # Options:
        #   full: true — export the full cached dir (ignores source_subdir).
        #                Useful for git monorepo checkouts.
        def export(target, force: false, full: false)
          if force && Dir.exist?(target)
            FileUtils.rm_rf(target)
          end

          return if Dir.exist?(target)
          return unless @cached_dir && Dir.exist?(@cached_dir)

          FileUtils.mkdir_p(File.dirname(target))
          if !full && @source_subdir
            FileUtils.cp_r(File.join(@cached_dir, @source_subdir), target)
          else
            FileUtils.cp_r(@cached_dir, target)
          end

          if @has_extensions
            Dir.glob(File.join(target, "lib", "**", "*.{so,bundle,dylib}")).each do |f|
              File.delete(f)
            end
          end

          @has_exported = true
        end

        def exported?
          @has_exported
        end

        # Generate a Nix expression that selects the correct platform string
        # for this gem based on stdenv.hostPlatform. Returns nil for non-platform gems.
        #
        # Example output for nokogiri:
        #   if hp.isDarwin then
        #     (if hp.isAarch64 then "arm64-darwin" else "x86_64-darwin")
        #   else if hp.isLinux then
        #     (if hp.isAarch64 then "aarch64-linux-gnu" else "x86_64-linux-gnu")
        #   else null
        #
        def nix_platform_expr
          return nil unless @is_platform_gem
          return nil if @platform_variants.empty?

          # Group variants by OS
          darwin = @platform_variants.select { |p| p.include?("darwin") }
          linux  = @platform_variants.reject { |p| p.include?("darwin") }

          parts = []
          parts << "if hp.isDarwin then"
          if darwin.size == 1
            parts << "  \"#{darwin.first}\""
          elsif darwin.size > 1
            arm = darwin.find { |p| p.start_with?("arm64") || p.start_with?("aarch64") }
            x86 = darwin.find { |p| p.start_with?("x86_64") }
            parts << "  (if hp.isAarch64 then \"#{arm || darwin.first}\" else \"#{x86 || darwin.first}\")"
          else
            parts << "  null"
          end

          parts << "else if hp.isLinux then"
          if linux.size == 1
            parts << "  \"#{linux.first}\""
          elsif linux.size > 1
            # Filter to non-musl for glibc systems, prefer exact match
            gnu = linux.select { |p| p.include?("gnu") || !p.include?("musl") }
            gnu = linux if gnu.empty?
            arm = gnu.find { |p| p.start_with?("aarch64") }
            x86 = gnu.find { |p| p.start_with?("x86_64") }
            parts << "  (if hp.isAarch64 then \"#{arm || gnu.first}\" else \"#{x86 || gnu.first}\")"
          else
            parts << "  null"
          end

          parts << "else null"
          parts.join("\n    ")
        end
      end

      module_function

      # Parse a lockfile and return ExportedGem objects for all non-PATH gems,
      # filtered to the current platform. Handles:
      # - Platform deduplication (prefers platform-specific over ruby)
      # - Git source detection (monorepo checkout dir computation)
      # - Monorepo subdir detection
      # - Metadata extraction (require_paths, executables, extensions)
      # - Git checkout merging (multiple sub-gems → one checkout dir)
      #
      # Returns: Array<ExportedGem>, Array<String> (path-skipped gem names)
      #
      def from_lockfile(bundle, abi: Platform.abi_key)
        cache    = bundle.cache
        lockfile = bundle.lockfile

        # Collect all platform variants per gem name (for cross-compilation maps)
        platform_variants = Hash.new { |h, k| h[k] = [] }
        lockfile.specs.each do |spec|
          plat = spec[:platform] || "ruby"
          platform_variants[spec[:name]] << plat if plat != "ruby"
        end

        # Filter to current platform, deduplicate, skip PATH sources
        path_skipped = []
        by_name = {}
        lockfile.specs.each do |spec|
          next unless Platform.match_platform?(spec[:platform])
          if spec[:source].is_a?(Source::Path)
            path_skipped << spec[:name]
            next
          end
          name = spec[:name]
          prev = by_name[name]
          if prev.nil? || (spec[:platform] != "ruby" && prev[:platform] == "ruby")
            by_name[name] = spec
          end
        end

        # Build ExportedGem for each
        gems = by_name.values.map do |spec|
          variants = platform_variants[spec[:name]]
          build_exported_gem(spec, cache, abi, platform_variants: variants)
        end

        # Merge git checkouts — for monorepos where scint caches each sub-gem
        # separately, all cached dirs need to be overlaid into one tree.
        merge_git_checkouts(gems)

        [gems, path_skipped]
      end

      # ------------------------------------------------------------------
      private
      # ------------------------------------------------------------------

      def self.build_exported_gem(spec, cache, abi, platform_variants: [])
        name    = spec[:name]
        version = spec[:version]
        lock_platform = spec[:platform] || "ruby"

        cached_dir    = cache.cached_path(spec, abi)
        manifest_path = cache.cached_manifest_path(spec, abi)

        # Extensions — check manifest first. If the manifest says no extensions,
        # also scan for extconf.rb — but only if there are no prebuilt .so files.
        # Prebuilt platform gems (e.g. nokogiri-x86_64-linux-gnu) ship both ext/
        # AND prebuilt .so in lib/; we keep the .so and skip recompilation.
        has_extensions = false
        if File.exist?(manifest_path)
          manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
          has_extensions = manifest.dig("build", "extensions") == true
        end
        if !has_extensions && Dir.exist?(cached_dir)
          has_extconf = !Dir.glob(File.join(cached_dir, "ext", "**", "extconf.rb")).empty?
          has_prebuilt = !Dir.glob(File.join(cached_dir, "lib", "**", "*.{so,bundle,dylib}")).empty?
          has_extensions = has_extconf && !has_prebuilt
        end

        # Monorepo subdir
        source_subdir = detect_source_subdir(cached_dir, name)

        # Metadata
        real_spec = load_spec_marshal(cached_dir)
        require_paths = extract_require_paths(real_spec, spec, cache)
        require_paths = verify_require_paths(require_paths, cached_dir, source_subdir)
        executables, bindir = extract_executables(real_spec, spec, cache)

        # Dependencies
        dependencies = (spec[:dependencies] || []).map { |d| d[:name] }

        # Git source
        git_checkout_dir = nil
        if spec[:source].is_a?(Source::Git)
          src = spec[:source]
          uri = src.uri
          base = File.basename(uri.sub(%r{^(\w+://)?([^/:]+:)?(//\w*/)?(\w*/)*}, ""), ".git")
          shortref = src.revision[0..11]
          git_checkout_dir = "#{base}-#{shortref}"
        end

        ExportedGem.new(
          name: name,
          version: version,
          dependencies: dependencies,
          has_extensions: has_extensions,
          require_paths: require_paths,
          executables: executables,
          bindir: bindir,
          is_platform_gem: lock_platform != "ruby",
          git_checkout_dir: git_checkout_dir,
          source_subdir: source_subdir,
          cached_dir: cached_dir,
          platform_variants: platform_variants,
        )
      end

      # For monorepo git sources (rails, azure-storage-ruby), merge all
      # sub-gem cached dirs into one tree under the first gem's cached_dir.
      # This is done lazily — the actual merge happens during export().
      def self.merge_git_checkouts(gems)
        git_gems = gems.select(&:git_source?)
        by_checkout = git_gems.group_by(&:git_checkout_dir)

        by_checkout.each do |_checkout_dir, group|
          next if group.size <= 1

          # All gems in the group share the same git checkout.
          # Create a merged cache dir that overlays all their sources.
          merged_dir = Dir.mktmpdir("scint-git-merge-")
          group.each do |gem|
            src = gem.instance_variable_get(:@cached_dir)
            next unless src && Dir.exist?(src)
            Dir.children(src).each do |child|
              dst = File.join(merged_dir, child)
              FileUtils.cp_r(File.join(src, child), dst) unless File.exist?(dst)
            end
          end

          # Point all gems in the group to the merged dir
          group.each do |gem|
            gem.instance_variable_set(:@cached_dir, merged_dir)
          end
        end
      end

      # ------------------------------------------------------------------
      # Internal helpers
      # ------------------------------------------------------------------

      def self.detect_source_subdir(cached_dir, name)
        return nil unless Dir.exist?(cached_dir)
        return nil if Dir.exist?(File.join(cached_dir, "lib"))

        candidate = File.join(cached_dir, name)
        name if Dir.exist?(candidate) && Dir.exist?(File.join(candidate, "lib"))
      end

      def self.load_spec_marshal(cached_dir)
        path = "#{cached_dir}.spec.marshal"
        return nil unless File.exist?(path)
        Marshal.load(File.binread(path)) rescue nil
      end

      def self.extract_require_paths(real_spec, spec, cache)
        if real_spec&.respond_to?(:require_paths) && real_spec.require_paths
          return real_spec.require_paths
        end

        read_gem_metadata(spec, cache) { |meta|
          meta.require_paths rescue meta["require_paths"] rescue nil
        } || ["lib"]
      end

      def self.verify_require_paths(require_paths, cached_dir, source_subdir)
        return require_paths unless Dir.exist?(cached_dir)

        base = source_subdir ? File.join(cached_dir, source_subdir) : cached_dir
        verified = require_paths.select { |p| Dir.exist?(File.join(base, p)) }
        verified.empty? ? require_paths : verified
      end

      def self.extract_executables(real_spec, spec, cache)
        if real_spec&.respond_to?(:executables) && !real_spec.executables.empty?
          return [real_spec.executables, real_spec.bindir || "exe"]
        end

        executables = nil
        bindir = nil
        read_gem_metadata(spec, cache) do |meta|
          executables = meta.executables rescue nil
          bindir = meta.bindir rescue nil
        end

        [executables || [], bindir || "exe"]
      end

      def self.read_gem_metadata(spec, cache)
        gem_path = cache.inbound_path(spec)
        return nil unless File.exist?(gem_path)

        File.open(gem_path, "rb") do |io|
          Gem::Package::TarReader.new(io) do |tar|
            tar.each do |entry|
              if entry.full_name == "metadata.gz"
                yaml = Zlib::GzipReader.new(StringIO.new(entry.read)).read
                meta = YAML.safe_load(yaml,
                  permitted_classes: [Gem::Specification, Gem::Version, Gem::Requirement,
                                     Gem::Dependency, Symbol, Time])
                return yield(meta)
              end
            end
          end
        end
        nil
      rescue
        nil
      end
    end
  end
end
