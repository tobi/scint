# frozen_string_literal: true

require_relative "../errors"
require_relative "../fs"
require "fileutils"
require "securerandom"

module Scint
  module Installer
    class Promoter
      attr_reader :root, :lock_dir, :staging_dir

      def initialize(root:, lock_dir: nil, staging_dir: nil)
        @root = File.expand_path(root.to_s)
        @lock_dir = File.expand_path(lock_dir.to_s) if lock_dir
        @staging_dir = File.expand_path(staging_dir.to_s) if staging_dir

        @lock_dir ||= File.join(@root, "locks", "promotion")
        @staging_dir ||= File.join(@root, "staging")
      end

      def with_lock(lock_key)
        lock_path = lock_path_for(lock_key)
        validate_within_root!(@root, lock_path, label: "lock")
        FS.mkdir_p(File.dirname(lock_path))

        File.open(lock_path, "w") do |file|
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      end

      def with_staging_dir(prefix:)
        FS.mkdir_p(@staging_dir)
        staging_path = File.join(@staging_dir, staging_suffix(prefix))
        validate_within_root!(@root, staging_path, label: "staging")
        FileUtils.rm_rf(staging_path) if File.exist?(staging_path)

        begin
          FS.mkdir_p(staging_path)
          yield staging_path
        ensure
          FileUtils.rm_rf(staging_path) if Dir.exist?(staging_path)
        end
      end

      def promote_tree(staging_path:, target_path:, lock_key:)
        validate_within_root!(@root, staging_path, label: "staging")
        validate_within_root!(@root, target_path, label: "target")
        raise CacheError, "Staging path does not exist: #{staging_path}" unless Dir.exist?(staging_path)

        with_lock(lock_key) do
          if Dir.exist?(target_path)
            FileUtils.rm_rf(staging_path) if Dir.exist?(staging_path)
            return :exists
          end

          begin
            FS.atomic_move(staging_path, target_path)
          rescue StandardError
            FileUtils.rm_rf(staging_path) if Dir.exist?(staging_path)
            raise
          end

          :promoted
        end
      end

      def validate_within_root!(root_path, candidate_path, label: "path")
        root_expanded = File.expand_path(root_path.to_s)
        candidate_expanded = File.expand_path(candidate_path.to_s)
        within_root = candidate_expanded == root_expanded ||
                      candidate_expanded.start_with?("#{root_expanded}/")
        return if within_root

        raise CacheError, "#{label.capitalize} escapes cache root: #{candidate_path}"
      end

      def lock_path_for(lock_key)
        safe_key = sanitize_key(lock_key)
        File.join(@lock_dir, "#{safe_key}.lock")
      end

      def sanitize_key(key)
        key.to_s.gsub(/[^0-9A-Za-z._-]/, "_")
      end

      def staging_suffix(prefix)
        safe = sanitize_key(prefix)
        token = SecureRandom.hex(6)
        "#{safe}.#{Process.pid}.#{Thread.current.object_id}.#{token}"
      end
    end
  end
end
