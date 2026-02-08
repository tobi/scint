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

      def extracted_dir
        File.join(@root, "extracted")
      end

      def ext_dir
        File.join(@root, "ext")
      end

      def index_dir
        File.join(@root, "index")
      end

      def git_dir
        File.join(inbound_dir, "git")
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
        File.join(inbound_dir, "#{full_name(spec)}.gem")
      end

      def extracted_path(spec)
        File.join(extracted_dir, full_name(spec))
      end

      def spec_cache_path(spec)
        File.join(extracted_dir, "#{full_name(spec)}.spec.marshal")
      end

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
        File.join(git_dir, "repos", slug)
      end

      def git_checkout_path(uri, revision)
        slug = git_slug(uri)
        rev = revision.to_s.gsub(/[^0-9A-Za-z._-]/, "_")
        File.join(git_dir, "checkouts", slug, rev)
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

      # Git slugs are SHA256 of the normalized URI string (uri.to_s), truncated
      # to 16 hex chars. Callers must validate `source.uri` in the manifest to
      # detect collisions and fall back to a longer hash if needed.
      def git_slug(uri)
        Digest::SHA256.hexdigest(uri.to_s)[0, 16]
      end
    end
  end
end
