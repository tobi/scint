# frozen_string_literal: true

require_relative "../runtime/exec"
require_relative "../fs"
require_relative "../platform"
require_relative "../spec_utils"
require_relative "../lockfile/parser"
require "pathname"

module Scint
  module CLI
    class Exec
      RUNTIME_LOCK = "scint.lock.marshal"

      def initialize(argv = [])
        @argv = argv
      end

      def run
        if @argv.empty?
          $stderr.puts "scint exec requires a command to run"
          return 1
        end

        command = @argv.first
        args = @argv[1..] || []

        lock_path = find_lock_path
        unless lock_path
          $stderr.puts "No runtime lock found. Run `scint install` first."
          return 1
        end

        # This calls Kernel.exec and never returns on success
        Runtime::Exec.exec(command, args, lock_path)
      end

      private

      def find_lock_path
        # Walk up from cwd looking for .bundle/scint.lock.marshal.
        # If missing but Gemfile.lock + installed gems exist, rebuild it.
        dir = Dir.pwd
        loop do
          bundle_dir = File.join(dir, ".bundle")
          candidate = File.join(dir, ".bundle", RUNTIME_LOCK)
          return candidate if File.exist?(candidate)

          rebuilt = rebuild_runtime_lock(dir, bundle_dir, candidate)
          return rebuilt if rebuilt

          parent = File.dirname(dir)
          break if parent == dir # reached root
          dir = parent
        end

        nil
      end

      def rebuild_runtime_lock(project_dir, bundle_dir, lock_path)
        return nil unless Dir.exist?(File.join(bundle_dir, "ruby"))

        gemfile_lock = File.join(project_dir, "Gemfile.lock")
        return nil unless File.exist?(gemfile_lock)

        ruby_dir = detect_ruby_dir(bundle_dir)
        return nil unless ruby_dir

        lockfile = Scint::Lockfile::Parser.parse(gemfile_lock)
        data = {}

        lockfile.specs.each do |spec|
          full = SpecUtils.full_name(spec)
          gem_dir = File.join(ruby_dir, "gems", full)
          next unless Dir.exist?(gem_dir)

          spec_file = File.join(ruby_dir, "specifications", "#{full}.gemspec")
          require_paths = read_require_paths(spec_file)
          load_paths = require_paths
            .map { |rp| expand_require_path(gem_dir, rp) }
            .select { |path| Dir.exist?(path) }

          lib_path = File.join(gem_dir, "lib")
          load_paths << lib_path if load_paths.empty? && Dir.exist?(lib_path)
          load_paths.uniq!

          ext_path = File.join(ruby_dir, "extensions",
                               Platform.gem_arch, Platform.extension_api_version, full)
          load_paths << ext_path if Dir.exist?(ext_path)

          data[spec[:name]] = {
            version: spec[:version].to_s,
            load_paths: load_paths,
          }
        end

        return nil if data.empty?

        FS.atomic_write(lock_path, Marshal.dump(data))
        lock_path
      rescue StandardError
        nil
      end

      def detect_ruby_dir(bundle_dir)
        target = Platform.ruby_minor_version_dir
        preferred = File.join(bundle_dir, "ruby", target)
        return preferred if Dir.exist?(preferred)

        dirs = Dir.glob(File.join(bundle_dir, "ruby", "*")).select { |path| Dir.exist?(path) }
        dirs.sort.first
      end

      def spec_full_name(spec)
        SpecUtils.full_name(spec)
      end

      def read_require_paths(spec_file)
        return ["lib"] unless File.exist?(spec_file)

        gemspec = SpecUtils.load_gemspec(spec_file)
        paths = Array(gemspec&.require_paths).reject(&:empty?)
        paths.empty? ? ["lib"] : paths
      rescue StandardError
        ["lib"]
      end

      def expand_require_path(gem_dir, require_path)
        value = require_path.to_s
        return value if Pathname.new(value).absolute?

        File.join(gem_dir, value)
      rescue StandardError
        File.join(gem_dir, require_path.to_s)
      end
    end
  end
end
