# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"
require_relative "../spec_utils"
require "digest"
require "uri"

module Scint
  module Cache
    class Layout
      attr_reader :root

      def initialize(root: nil)
        @root = root || default_root
        @ensured_dirs = {}
        @mutex = Thread::Mutex.new
      end

      # -- Top-level directories -----------------------------------------------

      def inbound_dir
        File.join(@root, "inbound")
      end

      def inbound_gems_dir
        File.join(inbound_dir, "gems")
      end

      def inbound_gits_dir
        File.join(inbound_dir, "gits")
      end

      def assembling_dir
        File.join(@root, "assembling")
      end

      def cached_dir
        File.join(@root, "cached")
      end

      # Legacy extracted cache (read-compat only).
      def extracted_dir
        File.join(@root, "extracted")
      end

      # Legacy extension cache (read-compat only).
      def ext_dir
        File.join(@root, "ext")
      end

      def index_dir
        File.join(@root, "index")
      end

      def git_dir
        inbound_gits_dir
      end

      # Isolated gem home used while compiling native extensions during install.
      # This keeps build-time gem activation hermetic to scint-managed paths.
      def install_env_dir
        File.join(@root, "install-env")
      end

      def install_ruby_dir
        Platform.ruby_install_dir(install_env_dir)
      end

      # -- Per-spec paths ------------------------------------------------------

      def inbound_path(spec)
        File.join(inbound_gems_dir, "#{full_name(spec)}.gem")
      end

      def assembling_path(spec, abi_key = Platform.abi_key)
        File.join(assembling_dir, abi_key, full_name(spec))
      end

      def cached_abi_dir(abi_key = Platform.abi_key)
        File.join(cached_dir, abi_key)
      end

      def cached_path(spec, abi_key = Platform.abi_key)
        File.join(cached_dir, abi_key, full_name(spec))
      end

      def cached_spec_path(spec, abi_key = Platform.abi_key)
        File.join(cached_dir, abi_key, "#{full_name(spec)}.spec.marshal")
      end

      def cached_manifest_path(spec, abi_key = Platform.abi_key)
        File.join(cached_dir, abi_key, "#{full_name(spec)}.manifest")
      end

      # Legacy extracted cache (read-compat only).
      def extracted_path(spec)
        File.join(extracted_dir, full_name(spec))
      end

      # Legacy extracted gemspec cache (read-compat only).
      def spec_cache_path(spec)
        File.join(extracted_dir, "#{full_name(spec)}.spec.marshal")
      end

      # Legacy extension cache (read-compat only).
      def ext_path(spec, abi_key = Platform.abi_key)
        File.join(ext_dir, abi_key, full_name(spec))
      end

      # -- Per-source paths ----------------------------------------------------

      def index_path(source)
        slug = if source.respond_to?(:cache_slug)
                 source.cache_slug
               else
                 slugify_uri(source.to_s)
               end
        File.join(index_dir, slug)
      end

      def git_path(uri)
        slug = git_slug(uri)
        File.join(git_dir, slug)
      end

      def git_checkout_path(uri, revision)
        slug = git_slug(uri)
        rev = revision.to_s.gsub(/[^0-9A-Za-z._-]/, "_")
        File.join(git_dir, slug, "checkouts", rev)
      end

      # -- Helpers -------------------------------------------------------------

      def full_name(spec)
        SpecUtils.full_name(spec)
      end

      # Ensure a directory exists (thread-safe, cached).
      def ensure_dir(path)
        return if @ensured_dirs[path]

        @mutex.synchronize do
          return if @ensured_dirs[path]
          FS.mkdir_p(path)
          @ensured_dirs[path] = true
        end
      end

      private

      def default_root
        return Scint.cache_root if Scint.respond_to?(:cache_root)

        explicit = ENV["SCINT_CACHE"]
        return File.expand_path(explicit) unless explicit.nil? || explicit.empty?

        base = ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache")
        File.join(base, "scint")
      end

      # Slug rules are defined in README.md (Cache Validity + Manifest Specification).
      # - Index slugs prefer host/path when available, otherwise fall back to a hash.
      # - Hash slugs are deterministic but must be paired with manifest checks for
      #   collision detection.
      def slugify_uri(str)
        uri = URI.parse(str) rescue nil
        if uri && uri.host
          path = uri.path.to_s.gsub("/", "-").sub(/^-/, "")
          slug = uri.host
          slug += path unless path.empty? || path == "-"
          slug
        else
          Digest::SHA256.hexdigest(str)[0, 16]
        end
      end

      # Human-decodable git slug: "github.com-Shopify-debug" for
      # https://github.com/Shopify/debug.git.  Falls back to truncated
      # SHA256 for URIs that don't parse cleanly.
      def git_slug(uri)
        normalized = normalize_uri(uri)
        parsed = URI.parse(normalized) rescue nil
        if parsed && parsed.host
          path = parsed.path.to_s
            .sub(/\.git\z/, "")        # strip trailing .git
            .gsub("/", "-")            # slashes to dashes
            .sub(/\A-/, "")            # strip leading dash
          slug = parsed.host
          slug += "-#{path}" unless path.empty?
          slug
        else
          Digest::SHA256.hexdigest(normalized)[0, 16]
        end
      end

      def normalize_uri(uri)
        return uri.to_s if uri.is_a?(URI)
        URI.parse(uri.to_s).to_s
      rescue URI::InvalidURIError
        uri.to_s
      end
    end
  end
end
