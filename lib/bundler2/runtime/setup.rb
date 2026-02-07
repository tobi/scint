# frozen_string_literal: true

module Bundler2
  module Runtime
    module Setup
      module_function

      # Load and return the Marshal'd lock data without modifying $LOAD_PATH.
      def load_lock(lock_path)
        unless File.exist?(lock_path)
          raise LoadError, "Runtime lock not found: #{lock_path}. Run `bundle2 install` first."
        end

        Marshal.load(File.binread(lock_path)) # rubocop:disable Security/MarshalLoad
      end

      # Set up $LOAD_PATH from a Marshal'd lock data file.
      # This is the fast path for in-process setup — <10ms.
      def setup(lock_path)
        lock_data = load_lock(lock_path)

        paths = []
        lock_data.each_value do |info|
          Array(info[:load_paths]).each do |p|
            paths << p if File.directory?(p)
          end
        end

        $LOAD_PATH.unshift(*paths)

        ENV["BUNDLE_GEMFILE"] ||= find_gemfile(File.dirname(lock_path))

        lock_data
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
