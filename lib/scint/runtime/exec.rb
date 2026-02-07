# frozen_string_literal: true

require_relative "setup"
require_relative "../fs"
require "base64"
require "pathname"

module Scint
  module Runtime
    module Exec
      module_function

      # Execute a command with the bundled environment.
      # Reads Marshal'd runtime config, sets RUBYLIB so the child process
      # has all gem load paths, then Kernel.exec replaces the process.
      #
      # command: the program to run (e.g. "rails")
      # args:    array of arguments
      # lock_path: path to .scint/scint.lock.marshal
      def exec(command, args, lock_path)
        original_env = ENV.to_hash
        lock_data = Setup.load_lock(lock_path)

        bundle_dir = File.dirname(lock_path)
        scint_lib_dir = File.expand_path("../..", __dir__)
        ruby_dir = File.join(bundle_dir, "ruby",
                             RUBY_VERSION.split(".")[0, 2].join(".") + ".0")

        # Collect all load paths from the runtime config
        paths = []
        lock_data.each_value do |info|
          Array(info[:load_paths]).each do |p|
            paths << p if File.directory?(p)
          end
        end

        # Ensure our bundler shim wins over global bundler.
        # Order matters: scint lib first, then gem load paths.
        paths.unshift(scint_lib_dir)

        # Set RUBYLIB so the child process inherits load paths.
        existing = ENV["RUBYLIB"]
        rubylib = paths.join(File::PATH_SEPARATOR)
        rubylib = "#{rubylib}#{File::PATH_SEPARATOR}#{existing}" if existing && !existing.empty?
        ENV["RUBYLIB"] = rubylib

        ENV["SCINT_RUNTIME_LOCK"] = lock_path
        ENV["GEM_HOME"] = ruby_dir
        ENV["GEM_PATH"] = ruby_dir
        ENV["BUNDLE_PATH"] = bundle_dir
        ENV["BUNDLE_APP_CONFIG"] = bundle_dir
        ENV["BUNDLE_GEMFILE"] = find_gemfile(bundle_dir)
        ENV["PATH"] = prepend_path(File.join(ruby_dir, "bin"), ENV["PATH"])
        ENV["PATH"] = prepend_path(File.join(bundle_dir, "bin"), ENV["PATH"])
        prepend_rubyopt("-rbundler/setup")
        export_original_env(original_env)

        command = resolve_command(command, bundle_dir, ruby_dir)

        # Kernel.exec replaces the process
        Kernel.exec(command, *args)
      end

      def find_gemfile(bundle_dir)
        project_root = File.dirname(bundle_dir)
        gemfile = File.join(project_root, "Gemfile")
        File.exist?(gemfile) ? gemfile : nil
      end

      def prepend_rubyopt(flag)
        parts = ENV["RUBYOPT"].to_s.split(/\s+/).reject(&:empty?)
        return if parts.include?(flag)

        ENV["RUBYOPT"] = ([flag] + parts).join(" ")
      end

      def prepend_path(prefix, current_path)
        return prefix unless current_path && !current_path.empty?
        return current_path if current_path.split(File::PATH_SEPARATOR).include?(prefix)

        "#{prefix}#{File::PATH_SEPARATOR}#{current_path}"
      end

      def export_original_env(original_env)
        ENV["SCINT_ORIGINAL_ENV"] ||= Base64.strict_encode64(Marshal.dump(original_env))
      rescue StandardError
        # Non-fatal: shim can fallback to current ENV.
      end

      def resolve_command(command, bundle_dir, ruby_dir)
        return command if command.include?(File::SEPARATOR)

        bundle_bin = File.join(bundle_dir, "bin")
        ruby_bin = File.join(ruby_dir, "bin")
        FS.mkdir_p(bundle_bin)

        bundle_candidate = File.join(bundle_bin, command)
        return bundle_candidate if File.executable?(bundle_candidate)

        ruby_candidate = File.join(ruby_bin, command)
        return ruby_candidate if File.executable?(ruby_candidate)

        gem_exec = find_gem_executable(ruby_dir, command)
        return command unless gem_exec

        write_bundle_exec_wrapper(bundle_candidate, gem_exec, bundle_bin)
        bundle_candidate
      end

      def find_gem_executable(ruby_dir, command)
        gems_dir = File.join(ruby_dir, "gems")
        return nil unless Dir.exist?(gems_dir)

        Dir.glob(File.join(gems_dir, "*")).sort.each do |gem_dir|
          %w[exe bin].each do |subdir|
            candidate = File.join(gem_dir, subdir, command)
            return candidate if File.file?(candidate)
          end
        end

        nil
      end

      def write_bundle_exec_wrapper(wrapper_path, target_path, bundle_bin)
        relative = Pathname.new(target_path).relative_path_from(Pathname.new(bundle_bin)).to_s
        content = <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true
          load File.expand_path("#{relative}", __dir__)
        RUBY
        FS.atomic_write(wrapper_path, content)
        File.chmod(0o755, wrapper_path)
      rescue StandardError
        # If wrapper creation fails, we'll still fall back to PATH lookup.
      end

      private_class_method :find_gemfile, :prepend_rubyopt, :prepend_path, :export_original_env,
                           :resolve_command, :find_gem_executable, :write_bundle_exec_wrapper
    end
  end
end
