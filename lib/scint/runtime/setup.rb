# frozen_string_literal: true

module Scint
  module Runtime
    module Setup
      module_function

      # Load and return the Marshal'd lock data without modifying $LOAD_PATH.
      def load_lock(lock_path)
        unless File.exist?(lock_path)
          raise LoadError, "Runtime lock not found: #{lock_path}. Run `scint install` first."
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
        hydrate_loaded_specs(lock_data)

        lock_data
      end

      def find_gemfile(bundle_dir)
        project_root = File.dirname(bundle_dir)
        gemfile = File.join(project_root, "Gemfile")
        File.exist?(gemfile) ? gemfile : nil
      end

      def hydrate_loaded_specs(lock_data)
        return unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        lock_data.each do |name, info|
          gem_name = name.to_s
          next if gem_name.empty? || Gem.loaded_specs[gem_name]

          version = info.is_a?(Hash) ? info[:version] : nil
          spec = find_installed_spec(gem_name, version)
          Gem.loaded_specs[gem_name] = spec if spec
        end
      rescue StandardError
        # Best-effort compatibility with gems expecting Gem.loaded_specs.
      end

      def find_installed_spec(gem_name, version)
        version_req = version.to_s.strip
        if !version_req.empty?
          exact = Gem::Specification.find_all_by_name(gem_name, version_req)
          return exact.find { |spec| spec.version.to_s == version_req } || exact.first
        end

        Gem::Specification.find_all_by_name(gem_name).max_by(&:version)
      rescue StandardError
        nil
      end

      private_class_method :find_gemfile, :hydrate_loaded_specs, :find_installed_spec
    end
  end
end
