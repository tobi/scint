# frozen_string_literal: true

require_relative "../runtime/exec"
require_relative "../fs"
require_relative "../platform"
require_relative "../lockfile/parser"

module Bundler2
  module CLI
    class Exec
      RUNTIME_LOCK = "bundler2.lock.marshal"

      def initialize(argv = [])
        @argv = argv
      end

      def run
        if @argv.empty?
          $stderr.puts "bundle2 exec requires a command to run"
          return 1
        end

        command = @argv.first
        args = @argv[1..] || []

        lock_path = find_lock_path
        unless lock_path
          $stderr.puts "No runtime lock found. Run `bundle2 install` first."
          return 1
        end

        # This calls Kernel.exec and never returns on success
        Runtime::Exec.exec(command, args, lock_path)
      end

      private

      def find_lock_path
        # Walk up from cwd looking for .bundle/bundler2.lock.marshal.
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

        lockfile = Bundler2::Lockfile::Parser.parse(gemfile_lock)
        data = {}

        lockfile.specs.each do |spec|
          full = spec_full_name(spec)
          gem_dir = File.join(ruby_dir, "gems", full)
          next unless Dir.exist?(gem_dir)

          spec_file = File.join(ruby_dir, "specifications", "#{full}.gemspec")
          require_paths = read_require_paths(spec_file)
          load_paths = require_paths
            .map { |rp| File.join(gem_dir, rp) }
            .select { |path| Dir.exist?(path) }

          lib_path = File.join(gem_dir, "lib")
          load_paths << lib_path if load_paths.empty? && Dir.exist?(lib_path)
          load_paths.concat(detect_nested_lib_paths(gem_dir))
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
        target = RUBY_VERSION.split(".")[0, 2].join(".") + ".0"
        preferred = File.join(bundle_dir, "ruby", target)
        return preferred if Dir.exist?(preferred)

        dirs = Dir.glob(File.join(bundle_dir, "ruby", "*")).select { |path| Dir.exist?(path) }
        dirs.sort.first
      end

      def spec_full_name(spec)
        name = spec[:name]
        version = spec[:version]
        platform = spec[:platform]
        base = "#{name}-#{version}"
        return base if platform.nil? || platform.to_s == "ruby" || platform.to_s.empty?

        "#{base}-#{platform}"
      end

      def read_require_paths(spec_file)
        return ["lib"] unless File.exist?(spec_file)

        gemspec = Gem::Specification.load(spec_file)
        paths = Array(gemspec&.require_paths).reject(&:empty?)
        paths.empty? ? ["lib"] : paths
      rescue StandardError
        ["lib"]
      end

      def detect_nested_lib_paths(gem_dir)
        lib_dir = File.join(gem_dir, "lib")
        return [] unless Dir.exist?(lib_dir)

        children = Dir.children(lib_dir)
        top_level_rb = children.any? do |entry|
          path = File.join(lib_dir, entry)
          File.file?(path) && entry.end_with?(".rb")
        end
        return [] if top_level_rb

        children
          .map { |entry| File.join(lib_dir, entry) }
          .select { |path| File.directory?(path) }
      end
    end
  end
end
