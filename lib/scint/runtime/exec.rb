# frozen_string_literal: true

require_relative "setup"
require_relative "../fs"
require "base64"
require "pathname"
require "rbconfig"

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
      # lock_path: path to .bundle/scint.lock.marshal
      def exec(command, args, lock_path)
        original_env = ENV.to_hash
        Setup.load_lock(lock_path)
        command, args = rewrite_bundle_exec(command, args)
        passthrough_bundle = bundle_command?(command)

        bundle_dir = File.dirname(lock_path)
        scint_lib_dir = File.expand_path("../..", __dir__)
        ruby_dir = File.join(bundle_dir, "ruby",
                             RUBY_VERSION.split(".")[0, 2].join(".") + ".0")

        # Set RUBYLIB to make our Bundler shim loadable. We intentionally avoid
        # injecting all gem load paths here because large apps can exceed exec
        # argument/environment limits when RUBYLIB gets too long.
        # Gem load paths are still activated via Scint::Runtime::Setup from
        # `-rbundler/setup`.
        unless passthrough_bundle
          existing = ENV["RUBYLIB"]
          rubylib = scint_lib_dir
          rubylib = "#{rubylib}#{File::PATH_SEPARATOR}#{existing}" if existing && !existing.empty?
          ENV["RUBYLIB"] = rubylib
        end

        ENV["SCINT_RUNTIME_LOCK"] = lock_path
        ENV["GEM_HOME"] = ruby_dir
        ENV["GEM_PATH"] = build_gem_path(ruby_dir, original_env["GEM_PATH"])
        ENV["BUNDLE_PATH"] = bundle_dir
        ENV["BUNDLE_APP_CONFIG"] = bundle_dir
        ENV["BUNDLE_GEMFILE"] = find_gemfile(bundle_dir)
        ruby_interpreter_bin = File.dirname(RbConfig.ruby)

        # Keep interpreter/bin ahead of .bundle/bin so `#!/usr/bin/env ruby`
        # resolves to the interpreter, not a gem-provided "ruby" executable.
        ENV["PATH"] = prepend_path(File.join(bundle_dir, "bin"), ENV["PATH"])
        ENV["PATH"] = prepend_path(File.join(ruby_dir, "bin"), ENV["PATH"])
        ENV["PATH"] = prepend_path(ruby_interpreter_bin, ENV["PATH"])
        prepend_rubyopt("-rbundler/setup") unless passthrough_bundle
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
        parts = current_path.split(File::PATH_SEPARATOR).reject(&:empty?)
        parts.delete(prefix)
        ([prefix] + parts).join(File::PATH_SEPARATOR)
      end

      def export_original_env(original_env)
        ENV["SCINT_ORIGINAL_ENV"] ||= Base64.strict_encode64(Marshal.dump(original_env))
      rescue StandardError
        # Non-fatal: shim can fallback to current ENV.
      end

      def build_gem_path(bundle_ruby_dir, original_gem_path)
        paths = [bundle_ruby_dir]
        if defined?(Gem) && Gem.respond_to?(:default_path)
          paths.concat(Array(Gem.default_path))
        end
        if original_gem_path && !original_gem_path.empty?
          paths.concat(original_gem_path.split(File::PATH_SEPARATOR))
        end
        paths.reject(&:empty?).uniq.join(File::PATH_SEPARATOR)
      end

      def bundle_command?(command)
        File.basename(command.to_s) == "bundle"
      end

      def rewrite_bundle_exec(command, args)
        return [command, args] unless bundle_command?(command)
        return [command, args] unless args.first == "exec"
        return [command, args] if args.length < 2

        [args[1], args[2..] || []]
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
                           :bundle_command?, :rewrite_bundle_exec, :build_gem_path,
                           :resolve_command, :find_gem_executable, :write_bundle_exec_wrapper
    end
  end
end
