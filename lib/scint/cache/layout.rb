# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"
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
        File.join(@root, "git")
      end

      # Isolated gem home used while compiling native extensions during install.
      # This keeps build-time gem activation hermetic to scint-managed paths.
      def install_env_dir
        File.join(@root, "install-env")
      end

      def install_ruby_dir
        File.join(install_env_dir, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
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
        slug = Digest::SHA256.hexdigest(uri.to_s)[0, 16]
        File.join(git_dir, slug)
      end

      # -- Helpers -------------------------------------------------------------

      def full_name(spec)
        name = spec.respond_to?(:name) ? spec.name : spec[:name]
        version = spec.respond_to?(:version) ? spec.version : spec[:version]
        platform = spec.respond_to?(:platform) ? spec.platform : spec[:platform]

        base = "#{name}-#{version}"
        if platform && platform.to_s != "ruby" && platform.to_s != ""
          "#{base}-#{platform}"
        else
          base
        end
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
    end
  end
end
