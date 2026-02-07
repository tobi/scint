# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"
require_relative "../errors"
require "open3"

module Bundler2
  module Installer
    module ExtensionBuilder
      module_function

      # Build native extensions for a prepared gem.
      # prepared_gem: PreparedGem struct
      # bundle_path:  .bundle/ root
      # abi_key:      e.g. "ruby-3.3.0-arm64-darwin24" (defaults to Platform.abi_key)
      def build(prepared_gem, bundle_path, cache_layout, abi_key: Platform.abi_key)
        spec = prepared_gem.spec
        ruby_dir = ruby_install_dir(bundle_path)

        # Check global extension cache first
        cached_ext = cache_layout.ext_path(spec, abi_key)
        if Dir.exist?(cached_ext) && File.exist?(File.join(cached_ext, "gem.build_complete"))
          link_extensions(cached_ext, ruby_dir, spec, abi_key)
          return true
        end

        # Build in a temp dir, then cache
        src_dir = prepared_gem.extracted_path
        ext_dirs = find_extension_dirs(src_dir)
        raise ExtensionBuildError, "No extension directories found for #{spec.name}" if ext_dirs.empty?

        FS.with_tempdir("bundler2-ext") do |tmpdir|
          build_dir = File.join(tmpdir, "build")
          install_dir = File.join(tmpdir, "install")
          FS.mkdir_p(build_dir)
          FS.mkdir_p(install_dir)

          ext_dirs.each do |ext_dir|
            compile_extension(ext_dir, build_dir, install_dir, src_dir, spec, ruby_dir)
          end

          # Write marker
          File.write(File.join(install_dir, "gem.build_complete"), "")

          # Cache globally
          FS.mkdir_p(File.dirname(cached_ext))
          FS.atomic_move(install_dir, cached_ext)
        end

        link_extensions(cached_ext, ruby_dir, spec, abi_key)
        true
      end

      # --- private ---

      def buildable_source_dir?(gem_dir)
        find_extension_dirs(gem_dir).any?
      end

      def find_extension_dirs(gem_dir)
        dirs = []

        # extconf.rb in ext/ subdirectories
        Dir.glob(File.join(gem_dir, "ext", "**", "extconf.rb")).each do |path|
          dirs << File.dirname(path)
        end

        # CMakeLists.txt in ext/
        Dir.glob(File.join(gem_dir, "ext", "**", "CMakeLists.txt")).each do |path|
          dir = File.dirname(path)
          dirs << dir unless dirs.include?(dir)
        end

        # Rakefile-based (look for Rakefile in ext/)
        if dirs.empty?
          Dir.glob(File.join(gem_dir, "ext", "**", "Rakefile")).each do |path|
            dirs << File.dirname(path)
          end
        end

        dirs.uniq
      end

      def compile_extension(ext_dir, build_dir, install_dir, gem_dir, spec, ruby_dir)
        env = build_env(gem_dir, ruby_dir)

        if File.exist?(File.join(ext_dir, "extconf.rb"))
          compile_extconf(ext_dir, build_dir, install_dir, env)
        elsif File.exist?(File.join(ext_dir, "CMakeLists.txt"))
          compile_cmake(ext_dir, build_dir, install_dir, env)
        elsif File.exist?(File.join(ext_dir, "Rakefile"))
          compile_rake(ext_dir, build_dir, install_dir, env)
        else
          raise ExtensionBuildError, "No known build system in #{ext_dir}"
        end
      end

      def compile_extconf(ext_dir, build_dir, install_dir, env)
        run_cmd(env, RbConfig.ruby, File.join(ext_dir, "extconf.rb"),
                "--with-opt-dir=#{RbConfig::CONFIG["prefix"]}",
                chdir: build_dir)
        run_cmd(env, "make", "-j#{Platform.cpu_count}", "-C", build_dir)
        run_cmd(env, "make", "install", "DESTDIR=", "sitearchdir=#{install_dir}", "sitelibdir=#{install_dir}",
                chdir: build_dir)
      end

      def compile_cmake(ext_dir, build_dir, install_dir, env)
        run_cmd(env, "cmake", ext_dir, "-B", build_dir,
                "-DCMAKE_INSTALL_PREFIX=#{install_dir}")
        run_cmd(env, "cmake", "--build", build_dir, "--parallel", Platform.cpu_count.to_s)
        run_cmd(env, "cmake", "--install", build_dir)
      end

      def compile_rake(ext_dir, build_dir, install_dir, env)
        run_cmd(env, RbConfig.ruby, "-S", "rake", "compile",
                chdir: ext_dir)
        # Copy built artifacts to install_dir
        Dir.glob(File.join(ext_dir, "**", "*.{so,bundle,dll,dylib}")).each do |so|
          FileUtils.cp(so, install_dir)
        end
      end

      def link_extensions(cached_ext, ruby_dir, spec, abi_key)
        ext_install_dir = File.join(ruby_dir, "extensions",
                                    Platform.gem_arch, Platform.extension_api_version,
                                    spec_full_name(spec))
        return if Dir.exist?(ext_install_dir)

        FS.hardlink_tree(cached_ext, ext_install_dir)
      end

      def build_env(gem_dir, ruby_dir)
        {
          "GEM_HOME" => ruby_dir,
          "GEM_PATH" => ruby_dir,
          "MAKEFLAGS" => "-j#{Platform.cpu_count}",
          "CFLAGS" => "-I#{RbConfig::CONFIG["rubyhdrdir"]} -I#{RbConfig::CONFIG["rubyarchhdrdir"]}",
        }
      end

      def run_cmd(env, *cmd, chdir: nil)
        opts = { chdir: chdir }.compact

        if ENV["BUNDLER2_DEBUG"]
          pid = Process.spawn(env, *cmd, **opts)
          _, status = Process.wait2(pid)
          unless status.success?
            raise ExtensionBuildError,
                  "Command failed (exit #{status.exitstatus}): #{cmd.join(" ")}"
          end
          return
        end

        out, err, status = Open3.capture3(env, *cmd, **opts)

        unless status.success?
          details = [out, err].join
          details = details.strip
          message = "Command failed (exit #{status.exitstatus}): #{cmd.join(" ")}"
          message = "#{message}\n#{details}" unless details.empty?
          raise ExtensionBuildError,
                message
        end
      end

      def spec_full_name(spec)
        name = spec.name
        version = spec.version
        plat = spec.respond_to?(:platform) ? spec.platform : nil
        base = "#{name}-#{version}"
        (plat.nil? || plat.to_s == "ruby" || plat.to_s.empty?) ? base : "#{base}-#{plat}"
      end

      def ruby_install_dir(bundle_path)
        File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      end

      private_class_method :find_extension_dirs, :compile_extension,
                           :compile_extconf, :compile_cmake, :compile_rake,
                           :link_extensions, :build_env, :run_cmd,
                           :spec_full_name, :ruby_install_dir
    end
  end
end
