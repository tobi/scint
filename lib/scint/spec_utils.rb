# frozen_string_literal: true
require "open3"
require "rbconfig"

module Scint
  module SpecUtils
    module_function

    GEMSPEC_LOAD_MUTEX = Thread::Mutex.new

    GEMSPEC_SUBPROCESS_LOADER = <<~'RUBY'
      path = ARGV.fetch(0)
      begin
        Dir.chdir(File.dirname(path)) do
          spec = Gem::Specification.load(path)
          exit(2) unless spec
          STDOUT.binmode
          STDOUT.write(Marshal.dump(spec))
        end
      rescue Exception => e
        warn("#{e.class}: #{e.message}")
        exit(1)
      end
    RUBY

    def name(spec)
      spec.respond_to?(:name) ? spec.name : spec[:name]
    end

    def version(spec)
      spec.respond_to?(:version) ? spec.version : spec[:version]
    end

    def platform(spec)
      return spec.platform if spec.respond_to?(:platform)
      return spec[:platform] if spec.is_a?(Hash)
      return nil unless spec.respond_to?(:[])

      spec[:platform]
    rescue NameError, ArgumentError
      nil
    end

    def platform_str(spec)
      platform_value(platform(spec))
    end

    def platform_value(platform)
      value = platform.nil? ? "ruby" : platform.to_s
      value.empty? ? "ruby" : value
    end

    def full_name(spec)
      base = "#{name(spec)}-#{version(spec)}"
      plat = platform_str(spec)
      return base if plat == "ruby"

      "#{base}-#{plat}"
    end

    def full_name_for(name, version, platform = "ruby")
      base = "#{name}-#{version}"
      plat = platform_value(platform)
      return base if plat == "ruby"

      "#{base}-#{plat}"
    end

    def full_key(spec)
      full_key_for(name(spec), version(spec), platform(spec))
    end

    def full_key_for(name, version, platform = "ruby")
      "#{name}-#{version}-#{platform_value(platform)}"
    end

    # Load a gemspec with path-sensitive fallback.
    #
    # Some gemspecs depend on process cwd (e.g. `require "./lib/..."`,
    # `File.read("README")`). A direct load can fail when evaluated from a
    # different working directory. For those failures, evaluate in a dedicated
    # subprocess that can safely chdir without affecting install worker threads.
    def load_gemspec(path, isolate: false)
      absolute = File.expand_path(path.to_s)
      return nil unless File.file?(absolute)
      return load_gemspec_in_subprocess(absolute) if isolate

      spec = load_gemspec_direct(absolute)
      return spec if spec

      load_gemspec_in_subprocess(absolute)
    rescue StandardError, ScriptError => e
      return load_gemspec_in_subprocess(absolute) if gemspec_path_context_error?(e)

      nil
    end

    def gemspec_path_context_error?(error)
      return true if error.is_a?(LoadError)
      return true if error.is_a?(Errno::ENOENT)

      message = error.message.to_s
      message.include?("conflicting chdir during another chdir block") ||
        message.include?("cannot load such file -- ./") ||
        message.include?("cannot load such file -- ../")
    end
    private_class_method :gemspec_path_context_error?

    def load_gemspec_direct(absolute_path)
      GEMSPEC_LOAD_MUTEX.synchronize do
        ::Gem::Specification.load(absolute_path)
      end
    end
    private_class_method :load_gemspec_direct

    def load_gemspec_in_subprocess(absolute_path)
      out, _err, status = Open3.capture3(
        RbConfig.ruby,
        "-rrubygems",
        "-e",
        GEMSPEC_SUBPROCESS_LOADER,
        absolute_path,
      )
      return nil unless status.success?
      return nil if out.nil? || out.empty?

      Marshal.load(out)
    rescue StandardError
      nil
    end
    private_class_method :load_gemspec_in_subprocess
  end
end
