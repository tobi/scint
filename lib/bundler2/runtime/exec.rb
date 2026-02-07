# frozen_string_literal: true

require_relative "setup"

module Bundler2
  module Runtime
    module Exec
      module_function

      # Execute a command with the bundled environment.
      # Reads Marshal'd runtime config, sets RUBYLIB so the child process
      # has all gem load paths, then Kernel.exec replaces the process.
      #
      # command: the program to run (e.g. "rails")
      # args:    array of arguments
      # lock_path: path to .bundle/bundler2.lock.marshal
      def exec(command, args, lock_path)
        lock_data = Setup.load_lock(lock_path)

        bundle_dir = File.dirname(lock_path)
        ruby_dir = File.join(bundle_dir, "ruby",
                             RUBY_VERSION.split(".")[0, 2].join(".") + ".0")

        # Collect all load paths from the runtime config
        paths = []
        lock_data.each_value do |info|
          Array(info[:load_paths]).each do |p|
            paths << p if File.directory?(p)
          end
        end

        # Set RUBYLIB so the child process inherits load paths
        existing = ENV["RUBYLIB"]
        rubylib = paths.join(File::PATH_SEPARATOR)
        rubylib = "#{rubylib}#{File::PATH_SEPARATOR}#{existing}" if existing && !existing.empty?
        ENV["RUBYLIB"] = rubylib

        ENV["GEM_HOME"] = ruby_dir
        ENV["GEM_PATH"] = ruby_dir
        ENV["BUNDLE_GEMFILE"] = find_gemfile(bundle_dir)

        # Kernel.exec replaces the process
        Kernel.exec(command, *args)
      end

      def find_gemfile(bundle_dir)
        project_root = File.dirname(bundle_dir)
        gemfile = File.join(project_root, "Gemfile")
        File.exist?(gemfile) ? gemfile : nil
      end

      private_class_method :find_gemfile
    end
  end
end
