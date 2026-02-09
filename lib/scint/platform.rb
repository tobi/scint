# frozen_string_literal: true

require "etc"
require "rbconfig"

module Scint
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
      spec_plat === local_platform
    end

    def ruby_engine
      RUBY_ENGINE
    end

    def ruby_version
      RUBY_VERSION
    end

    def ruby_minor_version_dir
      @ruby_minor_version_dir ||= RUBY_VERSION.split(".")[0, 2].join(".") + ".0"
    end

    def ruby_install_dir(base)
      File.join(base, "ruby", ruby_minor_version_dir)
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

    # Map a system triple (Nix-style or GNU-style) to the RubyGems platform
    # string that Bundler uses in lockfiles.
    #
    #   gem_platform_for_system("x86_64-linux")      => "x86_64-linux-gnu"
    #   gem_platform_for_system("aarch64-linux")      => "aarch64-linux-gnu"
    #   gem_platform_for_system("aarch64-darwin")      => "arm64-darwin"
    #   gem_platform_for_system("x86_64-darwin")       => "x86_64-darwin"
    #   gem_platform_for_system(nil)                   => local_platform.to_s
    #
    def gem_platform_for_system(system = nil)
      return local_platform.to_s.sub(/-?\d+\z/, "") if system.nil?

      parts = system.to_s.split("-", 2)
      cpu = parts[0]
      kernel = parts[1] || ""

      # Darwin: RubyGems uses "arm64" not "aarch64", and no OS version suffix
      if kernel.start_with?("darwin")
        cpu = "arm64" if cpu == "aarch64"
        "#{cpu}-darwin"
      elsif kernel.start_with?("linux")
        # RubyGems appends "-gnu" for glibc Linux
        "#{cpu}-linux-gnu"
      else
        "#{cpu}-#{kernel}"
      end
    end

    # Nix expression fragment that computes the gem platform from
    # stdenv.hostPlatform at eval time. Returns a string of Nix code
    # that evaluates to the gem platform string.
    #
    # Usage in generated .nix:
    #   let gemPlatform = <this expression>; in ...
    #
    def nix_gem_platform_expr
      <<~NIX.strip
        let hp = pkgs.stdenv.hostPlatform; in
          if hp.isDarwin then
            (if hp.isAarch64 then "arm64" else hp.parsed.cpu.name) + "-darwin"
          else if hp.isLinux then
            hp.parsed.cpu.name + "-linux-gnu"
          else
            hp.parsed.cpu.name + "-" + hp.parsed.kernel.name
      NIX
    end
  end
end
