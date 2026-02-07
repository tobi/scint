# frozen_string_literal: true

require "etc"
require "rbconfig"

module Bundler2
  module Platform
    module_function

    def cpu_count
      @cpu_count ||= Etc.nprocessors
    end

    def abi_key
      @abi_key ||= begin
        engine = RUBY_ENGINE          # "ruby", "jruby", etc.
        version = RUBY_VERSION        # "3.3.0"
        arch = RbConfig::CONFIG["arch"] # "arm64-darwin24"
        "#{engine}-#{version}-#{arch}"
      end
    end

    def local_platform
      @local_platform ||= ::Gem::Platform.local
    end

    def match_platform?(spec_platform)
      return true if spec_platform.nil?
      return true if spec_platform == "ruby"

      spec_plat = spec_platform.is_a?(::Gem::Platform) ? spec_platform : ::Gem::Platform.new(spec_platform)
      ::Gem::Platform.match_gem?(spec_plat, local_platform)
    end

    def ruby_engine
      RUBY_ENGINE
    end

    def ruby_version
      RUBY_VERSION
    end

    def extension_api_version
      ::Gem.extension_api_version
    end

    def arch
      RbConfig::CONFIG["arch"]
    end

    def gem_arch
      local_platform.to_s
    end

    def os
      RbConfig::CONFIG["host_os"]
    end

    def windows?
      !!(os =~ /mswin|mingw|cygwin/)
    end

    def macos?
      !!(os =~ /darwin/)
    end

    def linux?
      !!(os =~ /linux/)
    end
  end
end
