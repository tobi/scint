# frozen_string_literal: true

require "digest"
require "find"
require "json"

require_relative "../fs"
require_relative "../spec_utils"

module Scint
  module Cache
    module Manifest
      module_function

      VERSION = 1

      def build(spec:, gem_dir:, abi_key:, source:, extensions:)
        {
          "abi" => abi_key,
          "build" => build_block(extensions: extensions),
          "files" => collect_files(gem_dir),
          "full_name" => SpecUtils.full_name(spec),
          "source" => source,
          "version" => VERSION,
        }
      end

      def write(path, manifest)
        ordered = order_keys(manifest)
        json = JSON.generate(ordered)
        FS.atomic_write(path, json)
      end

      def collect_files(root)
        entries = []
        Find.find(root) do |path|
          next if path == root

          rel = path.delete_prefix("#{root}/")
          stat = File.lstat(path)

          if stat.symlink?
            target = File.readlink(path)
            entries << file_entry(rel, "symlink", stat, Digest::SHA256.hexdigest(target))
          elsif stat.directory?
            entries << dir_entry(rel, stat)
          else
            entries << file_entry(rel, "file", stat, Digest::SHA256.file(path).hexdigest)
          end
        end

        entries.sort_by { |entry| entry["path"] }
      end

      def build_block(extensions:)
        { "extensions" => !!extensions }
      end

      def order_keys(object)
        case object
        when Hash
          object.keys.sort.each_with_object({}) do |key, acc|
            acc[key] = order_keys(object[key])
          end
        when Array
          object.map { |entry| order_keys(entry) }
        else
          object
        end
      end

      def dir_entry(rel, stat)
        {
          "mode" => stat.mode & 0o777,
          "path" => rel,
          "size" => 0,
          "type" => "dir",
        }
      end

      def file_entry(rel, type, stat, sha)
        entry = {
          "mode" => stat.mode & 0o777,
          "path" => rel,
          "size" => stat.size,
          "type" => type,
        }
        entry["sha256"] = sha if sha
        entry
      end
    end
  end
end
