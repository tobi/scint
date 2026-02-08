# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"
require_relative "../errors"
require "open3"

module Scint
  module Installer
    module ExtensionBuilder
      module_function

      # Build native extensions for a prepared gem.
      # prepared_gem: PreparedGem struct
      # bundle_path:  .bundle/ root
      # abi_key:      e.g. "ruby-3.3.0-arm64-darwin24" (defaults to Platform.abi_key)
      def build(prepared_gem, bundle_path, cache_layout, abi_key: Platform.abi_key, compile_slots: 1, output_tail: nil)
        spec = prepared_gem.spec
        ruby_dir = ruby_install_dir(bundle_path)
        build_ruby_dir = cache_layout.install_ruby_dir

        # Check global extension cache first
        cached_ext = cache_layout.ext_path(spec, abi_key)
        if Dir.exist?(cached_ext) && File.exist?(File.join(cached_ext, "gem.build_complete"))
          link_extensions(cached_ext, ruby_dir, spec, abi_key)
          return true
        end

        # Build in a temp dir, then cache
        src_dir = prepared_gem.extracted_path
        FS.with_tempdir("scint-ext") do |tmpdir|
          # Stage the full gem source tree in an isolated workspace.
          # Many extconf scripts use paths like ../../vendor relative to ext/,
          # which only work when the full gem layout is preserved.
          staged_src_dir = File.join(tmpdir, "source")
          FS.clone_tree(src_dir, staged_src_dir)

          ext_dirs = find_extension_dirs(staged_src_dir)
          raise ExtensionBuildError, "No extension directories found for #{spec.name}" if ext_dirs.empty?

          build_root = File.join(tmpdir, "build")
          install_dir = File.join(tmpdir, "install")
          FS.mkdir_p(build_root)
          FS.mkdir_p(install_dir)

          ext_dirs.each_with_index do |ext_dir, idx|
            # Keep isolated build trees per extension directory. Some gems
            # invoke multiple CMake projects under ext/ and CMake caches are
            # source-tree specific.
            ext_build_dir = File.join(build_root, idx.to_s)
            FS.mkdir_p(ext_build_dir)
            compile_extension(ext_dir, ext_build_dir, install_dir, staged_src_dir, spec, build_ruby_dir, compile_slots, output_tail)
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

      # True when a completed global extension build exists for this spec + ABI.
      def cached_build_available?(spec, cache_layout, abi_key: Platform.abi_key)
        cached_ext = cache_layout.ext_path(spec, abi_key)
        Dir.exist?(cached_ext) && File.exist?(File.join(cached_ext, "gem.build_complete"))
      end

      # Link already-compiled extensions from global cache into bundle_path.
      # Returns true when cache was present and linked, false otherwise.
      def link_cached_build(prepared_gem, bundle_path, cache_layout, abi_key: Platform.abi_key)
        spec = prepared_gem.spec
        return false unless cached_build_available?(spec, cache_layout, abi_key: abi_key)

        ruby_dir = ruby_install_dir(bundle_path)
        cached_ext = cache_layout.ext_path(spec, abi_key)
        link_extensions(cached_ext, ruby_dir, spec, abi_key)
        true
      end

      # True when a gem has native extension sources that need compiling.
      # Platform-specific gems usually ship precompiled binaries and should
      # not be compiled from ext/ unless they lack support for this Ruby.
      def needs_build?(spec, gem_dir)
        platform = spec.respond_to?(:platform) ? spec.platform : nil
        if platform && !platform.to_s.empty? && platform.to_s != "ruby"
          return prebuilt_missing_for_ruby?(gem_dir) && buildable_source_dir?(gem_dir)
        end

        buildable_source_dir?(gem_dir)
      end

      # Detect versioned prebuilt extension folders like:
      #   lib/sqlite3/3.1, lib/sqlite3/3.2 ...
      # If present, the current Ruby minor must exist or we need a build.
      def prebuilt_missing_for_ruby?(gem_dir)
        ruby_minor = RUBY_VERSION[/\d+\.\d+/]
        lib_dir = File.join(gem_dir, "lib")
        return false unless Dir.exist?(lib_dir)

        Dir.children(lib_dir).each do |child|
          child_path = File.join(lib_dir, child)
          next unless File.directory?(child_path)

          version_dirs = Dir.children(child_path).select do |entry|
            File.directory?(File.join(child_path, entry)) && entry.match?(/\A\d+\.\d+\z/)
          end
          next if version_dirs.empty?

          return true unless version_dirs.include?(ruby_minor)
        end

        false
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

        # CMakeLists.txt in ext/. Keep only top-level CMake roots, so vendored
        # subprojects (e.g. deps/*) are not built standalone.
        cmake_dirs = Dir.glob(File.join(gem_dir, "ext", "**", "CMakeLists.txt"))
                        .map { |path| File.dirname(path) }
                        .uniq
                        .sort_by { |dir| [dir.length, dir] }
        cmake_roots = []
        cmake_dirs.each do |dir|
          next if cmake_roots.any? { |root| dir.start_with?("#{root}/") }
          cmake_roots << dir
        end
        cmake_roots.each do |dir|
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

      def compile_extension(ext_dir, build_dir, install_dir, gem_dir, spec, build_ruby_dir, compile_slots, output_tail = nil)
        make_jobs = adaptive_make_jobs(compile_slots)
        env = build_env(gem_dir, build_ruby_dir, make_jobs)

        if File.exist?(File.join(ext_dir, "extconf.rb"))
          compile_extconf(ext_dir, gem_dir, build_dir, install_dir, env, make_jobs, output_tail)
        elsif File.exist?(File.join(ext_dir, "CMakeLists.txt"))
          compile_cmake(ext_dir, build_dir, install_dir, env, make_jobs, output_tail)
        elsif File.exist?(File.join(ext_dir, "Rakefile"))
          compile_rake(ext_dir, build_dir, install_dir, build_ruby_dir, env, output_tail)
        else
          raise ExtensionBuildError, "No known build system in #{ext_dir}"
        end
      end

      def compile_extconf(ext_dir, gem_dir, build_dir, install_dir, env, make_jobs, output_tail = nil)
        # Build in-place within the staged ext directory so extconf scripts
        # that navigate relative paths (../../vendor, ../..) behave like
        # Bundler's install layout.
        _ = gem_dir
        _ = build_dir
        run_cmd(env, RbConfig.ruby, File.join(ext_dir, "extconf.rb"),
                "--with-opt-dir=#{RbConfig::CONFIG["prefix"]}",
                chdir: ext_dir, output_tail: output_tail)
        run_cmd(env, "make", "-j#{make_jobs}", "-C", ext_dir, output_tail: output_tail)
        run_cmd(env, "make", "install", "DESTDIR=", "sitearchdir=#{install_dir}", "sitelibdir=#{install_dir}",
                chdir: ext_dir, output_tail: output_tail)
      end

      def compile_cmake(ext_dir, build_dir, install_dir, env, make_jobs, output_tail = nil)
        run_cmd(env, "cmake", ext_dir, "-B", build_dir,
                "-DCMAKE_INSTALL_PREFIX=#{install_dir}", output_tail: output_tail)
        run_cmd(env, "cmake", "--build", build_dir, "--parallel", make_jobs.to_s, output_tail: output_tail)
        run_cmd(env, "cmake", "--install", build_dir, output_tail: output_tail)
      end

      def compile_rake(ext_dir, build_dir, install_dir, ruby_dir, env, output_tail = nil)
        rake_exe = find_rake_executable(ruby_dir)
        begin
          if rake_exe
            run_cmd(env, RbConfig.ruby, rake_exe, "compile",
                    chdir: ext_dir, output_tail: output_tail)
          else
            run_cmd(env, RbConfig.ruby, "-S", "rake", "compile",
                    chdir: ext_dir, output_tail: output_tail)
          end
        rescue ExtensionBuildError => e
          # Some gems ship a Rakefile but do not expose a compile task.
          # Treat this as "nothing to build" rather than a hard failure.
          raise unless e.message.include?("Don't know how to build task 'compile'")
          return
        end
        # Copy built artifacts to install_dir
        Dir.glob(File.join(ext_dir, "**", "*.{so,bundle,dll,dylib}")).each do |so|
          FileUtils.cp(so, install_dir)
        end
      end

      def find_rake_executable(ruby_dir)
        gems_dir = File.join(ruby_dir, "gems")
        return nil unless Dir.exist?(gems_dir)

        # Prefer highest installed rake version.
        rake_dirs = Dir.glob(File.join(gems_dir, "rake-*")).sort.reverse
        rake_dirs.each do |dir|
          %w[exe bin].each do |subdir|
            path = File.join(dir, subdir, "rake")
            return path if File.file?(path)
          end
        end
        nil
      end

      def link_extensions(cached_ext, ruby_dir, spec, abi_key)
        ext_install_dir = File.join(ruby_dir, "extensions",
                                    Platform.gem_arch, Platform.extension_api_version,
                                    spec_full_name(spec))
        return if Dir.exist?(ext_install_dir)

        FS.clone_tree(cached_ext, ext_install_dir)
      end

      def build_env(gem_dir, build_ruby_dir, make_jobs)
        ruby_bin = File.join(build_ruby_dir, "bin")
        path = [ruby_bin, ENV["PATH"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
        {
          "GEM_HOME" => build_ruby_dir,
          "GEM_PATH" => build_ruby_dir,
          "BUNDLE_PATH" => build_ruby_dir,
          "BUNDLE_GEMFILE" => "",
          "MAKEFLAGS" => "-j#{make_jobs}",
          "PATH" => path,
          "CFLAGS" => "-I#{RbConfig::CONFIG["rubyhdrdir"]} -I#{RbConfig::CONFIG["rubyarchhdrdir"]}",
        }
      end

      def adaptive_make_jobs(compile_slots)
        slots = [compile_slots.to_i, 1].max
        jobs = Platform.cpu_count / slots
        [jobs, 1].max
      end

      def run_cmd(env, *cmd, chdir: nil, output_tail: nil)
        opts = { chdir: chdir }.compact

        if ENV["SCINT_DEBUG"]
          pid = Process.spawn(env, *cmd, **opts)
          _, status = Process.wait2(pid)
          unless status.success?
            raise ExtensionBuildError,
                  "Command failed (exit #{status.exitstatus}): #{cmd.join(" ")}"
          end
          return
        end

        # Stream output line-by-line so the UX gets live compile progress
        # instead of waiting for the entire subprocess to finish.
        all_output = +""
        tail_lines = []
        cmd_label = "$ #{cmd.join(" ")}"

        Open3.popen2e(env, *cmd, **opts) do |stdin, out_err, wait_thr|
          stdin.close

          out_err.each_line do |line|
            stripped = line.rstrip
            all_output << line
            next if stripped.empty?

            tail_lines << stripped
            tail_lines.shift if tail_lines.length > 5

            if output_tail
              output_tail.call([cmd_label, *tail_lines])
            end
          end

          status = wait_thr.value
          unless status.success?
            details = all_output.strip
            message = "Command failed (exit #{status.exitstatus}): #{cmd.join(" ")}"
            message = "#{message}\n#{details}" unless details.empty?
            raise ExtensionBuildError, message
          end
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
                           :find_rake_executable, :link_extensions, :build_env, :run_cmd,
                           :spec_full_name, :ruby_install_dir, :prebuilt_missing_for_ruby?
    end
  end
end
