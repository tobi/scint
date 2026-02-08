# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/extension_builder"
require "scint/cache/layout"

class ExtensionBuilderTest < Minitest::Test
  Prepared = Struct.new(:spec, :extracted_path, :gemspec, :from_cache, keyword_init: true)

  def test_build_noops_when_marker_present
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, Scint::Installer::ExtensionBuilder::BUILD_MARKER), "")
      prepared = Prepared.new(spec: spec, extracted_path: src, gemspec: nil, from_cache: true)

      Scint::Installer::ExtensionBuilder.stub(:find_extension_dirs, ->(_src) { raise "should not run" }) do
        assert Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout)
      end
    end
  end

  def test_cached_build_available_checks_marker
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")

      cached_dir = layout.cached_path(spec)
      FileUtils.mkdir_p(cached_dir)

      assert_equal false, Scint::Installer::ExtensionBuilder.cached_build_available?(spec, layout)

      File.write(File.join(cached_dir, Scint::Installer::ExtensionBuilder::BUILD_MARKER), "")
      assert_equal true, Scint::Installer::ExtensionBuilder.cached_build_available?(spec, layout)
    end
  end

  def test_link_cached_build_reports_marker
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")
      prepared = Prepared.new(spec: spec, extracted_path: File.join(dir, "src"), gemspec: nil, from_cache: true)

      cached_dir = layout.cached_path(spec)
      FileUtils.mkdir_p(cached_dir)
      File.write(File.join(cached_dir, Scint::Installer::ExtensionBuilder::BUILD_MARKER), "")

      assert_equal true, Scint::Installer::ExtensionBuilder.link_cached_build(prepared, bundle_path, layout)
    end
  end

  def test_build_raises_when_no_extension_directories_exist
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      extracted = File.join(dir, "extracted")
      FileUtils.mkdir_p(extracted)
      spec = fake_spec(name: "native", version: "0.1.0")
      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: nil, from_cache: true)

      error = assert_raises(Scint::ExtensionBuildError) do
        Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout, abi_key: "ruby-test")
      end

      assert_includes error.message, "No extension directories found"
    end
  end

  def test_find_extension_dirs_prefers_extconf_and_cmake_when_present
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "a"))
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "b"))
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "c"))

      File.write(File.join(gem_dir, "ext", "a", "extconf.rb"), "")
      File.write(File.join(gem_dir, "ext", "b", "CMakeLists.txt"), "")
      File.write(File.join(gem_dir, "ext", "c", "Rakefile"), "")

      dirs = Scint::Installer::ExtensionBuilder.send(:find_extension_dirs, gem_dir)
      assert_includes dirs, File.join(gem_dir, "ext", "a")
      assert_includes dirs, File.join(gem_dir, "ext", "b")
      refute_includes dirs, File.join(gem_dir, "ext", "c")
    end
  end

  def test_find_extension_dirs_uses_rake_when_only_rakefile_exists
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "c"))
      File.write(File.join(gem_dir, "ext", "c", "Rakefile"), "")

      dirs = Scint::Installer::ExtensionBuilder.send(:find_extension_dirs, gem_dir)
      assert_equal [File.join(gem_dir, "ext", "c")], dirs
    end
  end

  def test_find_extension_dirs_ignores_nested_cmake_subprojects
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "gem")
      top = File.join(gem_dir, "ext", "cppjieba")
      nested = File.join(gem_dir, "ext", "cppjieba", "deps", "limonp")
      sibling = File.join(gem_dir, "ext", "other")
      [top, nested, sibling].each { |path| FileUtils.mkdir_p(path) }

      File.write(File.join(top, "CMakeLists.txt"), "")
      File.write(File.join(nested, "CMakeLists.txt"), "")
      File.write(File.join(sibling, "CMakeLists.txt"), "")

      dirs = Scint::Installer::ExtensionBuilder.send(:find_extension_dirs, gem_dir)
      assert_includes dirs, top
      assert_includes dirs, sibling
      refute_includes dirs, nested
    end
  end

  def test_build_env_sets_expected_keys
    env = Scint::Installer::ExtensionBuilder.send(:build_env, "/tmp/src", "/tmp/cache/install-env/ruby/3.4.0", 3)

    assert env.key?("MAKEFLAGS")
    assert env.key?("CFLAGS")
    assert_equal "/tmp/cache/install-env/ruby/3.4.0", env["GEM_HOME"]
    assert_equal "/tmp/cache/install-env/ruby/3.4.0", env["GEM_PATH"]
    assert_equal "/tmp/cache/install-env/ruby/3.4.0", env["BUNDLE_PATH"]
    assert_equal "", env["BUNDLE_GEMFILE"]
    assert_equal "-j3", env["MAKEFLAGS"]
  end

  def test_adaptive_make_jobs_scales_by_compile_slots
    Scint::Platform.stub(:cpu_count, 12) do
      assert_equal 12, Scint::Installer::ExtensionBuilder.send(:adaptive_make_jobs, 1)
      assert_equal 6, Scint::Installer::ExtensionBuilder.send(:adaptive_make_jobs, 2)
      assert_equal 4, Scint::Installer::ExtensionBuilder.send(:adaptive_make_jobs, 3)
    end
  end

  def test_buildable_source_dir_false_for_non_native_ext_tree
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "concurrent-ruby"))
      File.write(File.join(gem_dir, "ext", "concurrent-ruby", "ConcurrentRubyService.java"), "")

      assert_equal false, Scint::Installer::ExtensionBuilder.buildable_source_dir?(gem_dir)
    end
  end

  def test_needs_build_false_for_platform_gem_with_matching_prebuilt_dir
    with_tmpdir do |dir|
      ruby_minor = RUBY_VERSION[/\d+\.\d+/]
      spec = fake_spec(name: "sqlite3", version: "2.0.0", platform: "x86_64-linux")
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "sqlite3"))
      File.write(File.join(gem_dir, "ext", "sqlite3", "extconf.rb"), "")
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "sqlite3", ruby_minor))

      assert_equal false, Scint::Installer::ExtensionBuilder.needs_build?(spec, gem_dir)
    end
  end

  def test_needs_build_true_for_platform_gem_without_matching_prebuilt_dir
    with_tmpdir do |dir|
      ruby_minor = RUBY_VERSION[/\d+\.\d+/]
      missing = ruby_minor == "3.4" ? "3.3" : "3.4"
      spec = fake_spec(name: "sqlite3", version: "2.0.0", platform: "x86_64-linux")
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "sqlite3"))
      File.write(File.join(gem_dir, "ext", "sqlite3", "extconf.rb"), "")
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "sqlite3", missing))

      assert_equal true, Scint::Installer::ExtensionBuilder.needs_build?(spec, gem_dir)
    end
  end

  def test_run_cmd_includes_captured_output_on_failure
    env = {}
    error = assert_raises(Scint::ExtensionBuildError) do
      Scint::Installer::ExtensionBuilder.send(
        :run_cmd,
        env,
        RbConfig.ruby,
        "-e",
        'STDOUT.puts("out line"); STDERR.puts("err line"); exit 12',
      )
    end

    assert_includes error.message, "exit 12"
    assert_includes error.message, "out line"
    assert_includes error.message, "err line"
  end

  def test_compile_rake_treats_missing_compile_task_as_noop
    with_tmpdir do |dir|
      ext_dir = File.join(dir, "ext")
      build_dir = File.join(dir, "build")
      install_dir = File.join(dir, "install")
      ruby_dir = File.join(dir, ".bundle", "ruby", "3.4.0")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(build_dir)
      FileUtils.mkdir_p(install_dir)
      FileUtils.mkdir_p(ruby_dir)

      missing_compile = Scint::ExtensionBuildError.new("rake aborted!\nDon't know how to build task 'compile'")
      Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(*_args, **_opts) { raise missing_compile }) do
        # Should not raise for missing compile task.
        Scint::Installer::ExtensionBuilder.send(
          :compile_rake,
          ext_dir,
          build_dir,
          install_dir,
          ruby_dir,
          {},
        )
      end
    end
  end

  def test_compile_extconf_uses_adaptive_make_jobs
    with_tmpdir do |dir|
      ext_dir = File.join(dir, "ext")
      build_dir = File.join(dir, "build")
      install_dir = File.join(dir, "install")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(build_dir)
      FileUtils.mkdir_p(install_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "puts 'ok'\n")

      calls = []
      Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(env, *cmd, **opts) { calls << { env: env, cmd: cmd, opts: opts } }) do
        Scint::Installer::ExtensionBuilder.send(
          :compile_extconf,
          ext_dir,
          ext_dir,
          build_dir,
          install_dir,
          { "MAKEFLAGS" => "-j5" },
          5,
        )
      end

      assert_equal 3, calls.size
      assert_equal ["make", "-j5", "-C", ext_dir], calls[1][:cmd]
    end
  end

  def test_compile_extconf_runs_from_staged_extension_dir
    with_tmpdir do |dir|
      ext_dir = File.join(dir, "ext")
      build_dir = File.join(dir, "build")
      install_dir = File.join(dir, "install")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(build_dir)
      FileUtils.mkdir_p(install_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "puts 'ok'\n")
      FileUtils.mkdir_p(File.join(ext_dir, "src"))

      calls = []
      Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(_env, *cmd, **_opts) { calls << cmd }) do
        Scint::Installer::ExtensionBuilder.send(
          :compile_extconf,
          ext_dir,
          ext_dir,
          build_dir,
          install_dir,
          {},
          2,
        )
      end

      assert File.exist?(File.join(ext_dir, "extconf.rb"))
      assert_equal File.join(ext_dir, "extconf.rb"), calls[0][1]
    end
  end

  def test_compile_extconf_runs_nested_ext_in_place
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "debug-gem")
      ext_dir = File.join(gem_dir, "ext", "debug")
      build_dir = File.join(dir, "build")
      install_dir = File.join(dir, "install")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "debug"))
      File.write(File.join(gem_dir, "lib", "debug", "version.rb"), "module DEBUGGER__; VERSION = 'x'; end\n")
      File.write(File.join(ext_dir, "extconf.rb"), "puts 'ok'\n")

      calls = []
      Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(_env, *cmd, **opts) { calls << { cmd: cmd, opts: opts } }) do
        Scint::Installer::ExtensionBuilder.send(
          :compile_extconf,
          ext_dir,
          gem_dir,
          build_dir,
          install_dir,
          {},
          2,
        )
      end

      assert File.exist?(File.join(gem_dir, "lib", "debug", "version.rb"))
      assert_equal File.join(ext_dir, "extconf.rb"), calls[0][:cmd][1]
      assert_equal ext_dir, calls[0][:opts][:chdir]
      assert_equal ["make", "-j2", "-C", ext_dir], calls[1][:cmd]
    end
  end

  def test_run_cmd_emits_tail_callback_with_command
    seen = nil
    Scint::Installer::ExtensionBuilder.send(
      :run_cmd,
      {},
      RbConfig.ruby,
      "-e",
      'STDOUT.puts("hello")',
      output_tail: ->(lines) { seen = lines },
    )

    refute_nil seen
    assert_equal true, seen.first.start_with?("$ ")
    assert_includes seen.join("\n"), "hello"
  end

  def test_build_full_flow_cache_miss
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "native", version: "1.0.0")
      abi_key = "ruby-test-arch"

      # Create source directory with extconf.rb
      extracted = File.join(dir, "src")
      ext_dir = File.join(extracted, "ext", "native")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: nil, from_cache: false)

      # Stub compile_extension to simulate a successful build
      Scint::Installer::ExtensionBuilder.stub(:compile_extension, lambda { |ext, build, install, *args|
        File.write(File.join(install, "native.so"), "binary")
      }) do
        assert Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout, abi_key: abi_key)
      end

      # Verify build artifacts were synced into the source tree
      assert File.exist?(File.join(extracted, "lib", "native.so"))
      assert File.exist?(File.join(extracted, Scint::Installer::ExtensionBuilder::BUILD_MARKER))
    end
  end

  def test_build_uses_distinct_build_dirs_for_multiple_extensions
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "native", version: "1.0.0")
      extracted = File.join(dir, "src")
      FileUtils.mkdir_p(extracted)
      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: nil, from_cache: false)
      abi_key = "ruby-test-arch"

      ext_dirs = [File.join(extracted, "ext", "a"), File.join(extracted, "ext", "b")]
      build_dirs = []

      Scint::Installer::ExtensionBuilder.stub(:find_extension_dirs, ->(_src) { ext_dirs }) do
        Scint::Installer::ExtensionBuilder.stub(:compile_extension, lambda { |_ext, build, *_rest|
          build_dirs << build
        }) do
          assert Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout, abi_key: abi_key)
        end
      end

      assert_equal 2, build_dirs.size
      assert_equal 2, build_dirs.uniq.size
    end
  end

  def test_build_stages_full_source_tree_for_extconf_relative_paths
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "brotli-like", version: "1.0.0")
      extracted = File.join(dir, "src")
      ext_dir = File.join(extracted, "ext", "brotli")
      vendor_dir = File.join(extracted, "vendor", "brotli", "c", "enc")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(vendor_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
      File.write(File.join(vendor_dir, "README"), "ok")
      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: nil, from_cache: false)

      staged_vendor_checks = []
      Scint::Installer::ExtensionBuilder.stub(:compile_extension, lambda { |ext, _build, install, gem_root, *_rest|
        staged_vendor_checks << File.exist?(File.join(gem_root, "vendor", "brotli", "c", "enc", "README"))
        File.write(File.join(install, "brotli_like.bundle"), "binary")
      }) do
        assert Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout, abi_key: "ruby-test-arch")
      end

      assert_equal [true], staged_vendor_checks
    end
  end

  def test_compile_extension_routes_to_extconf
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:compile_extconf, ->(ext_dir, gem_dir, build_dir, install_dir, env, make_jobs, output_tail) { calls << :extconf }) do
      with_tmpdir do |dir|
        ext_dir = File.join(dir, "ext")
        FileUtils.mkdir_p(ext_dir)
        File.write(File.join(ext_dir, "extconf.rb"), "")

        Scint::Installer::ExtensionBuilder.send(
          :compile_extension,
          ext_dir, "/tmp/build", "/tmp/install", dir,
          fake_spec(name: "x", version: "1.0.0"),
          "/tmp/ruby", 1,
        )
      end
    end

    assert_equal [:extconf], calls
  end

  def test_compile_extension_routes_to_cmake
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:compile_cmake, ->(ext_dir, build_dir, install_dir, env, make_jobs, output_tail) { calls << :cmake }) do
      with_tmpdir do |dir|
        ext_dir = File.join(dir, "ext")
        FileUtils.mkdir_p(ext_dir)
        File.write(File.join(ext_dir, "CMakeLists.txt"), "")

        Scint::Installer::ExtensionBuilder.send(
          :compile_extension,
          ext_dir, "/tmp/build", "/tmp/install", dir,
          fake_spec(name: "x", version: "1.0.0"),
          "/tmp/ruby", 1,
        )
      end
    end

    assert_equal [:cmake], calls
  end

  def test_compile_extension_routes_to_rake
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:compile_rake, ->(ext_dir, build_dir, install_dir, ruby_dir, env, output_tail) { calls << :rake }) do
      with_tmpdir do |dir|
        ext_dir = File.join(dir, "ext")
        FileUtils.mkdir_p(ext_dir)
        File.write(File.join(ext_dir, "Rakefile"), "")

        Scint::Installer::ExtensionBuilder.send(
          :compile_extension,
          ext_dir, "/tmp/build", "/tmp/install", dir,
          fake_spec(name: "x", version: "1.0.0"),
          "/tmp/ruby", 1,
        )
      end
    end

    assert_equal [:rake], calls
  end

  def test_compile_extension_raises_for_unknown_build_system
    with_tmpdir do |dir|
      ext_dir = File.join(dir, "ext")
      FileUtils.mkdir_p(ext_dir)

      error = assert_raises(Scint::ExtensionBuildError) do
        Scint::Installer::ExtensionBuilder.send(
          :compile_extension,
          ext_dir, "/tmp/build", "/tmp/install", dir,
          fake_spec(name: "x", version: "1.0.0"),
          "/tmp/ruby", 1,
        )
      end

      assert_includes error.message, "No known build system"
    end
  end

  def test_find_rake_executable_finds_highest_version
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby")
      gems_dir = File.join(ruby_dir, "gems")

      rake_old = File.join(gems_dir, "rake-13.0.0", "exe")
      rake_new = File.join(gems_dir, "rake-13.2.1", "exe")
      FileUtils.mkdir_p(rake_old)
      FileUtils.mkdir_p(rake_new)
      File.write(File.join(rake_old, "rake"), "#!/usr/bin/env ruby")
      File.write(File.join(rake_new, "rake"), "#!/usr/bin/env ruby")

      result = Scint::Installer::ExtensionBuilder.send(:find_rake_executable, ruby_dir)
      assert_equal File.join(rake_new, "rake"), result
    end
  end

  def test_find_rake_executable_prefers_exe_over_bin
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby")
      rake_dir = File.join(ruby_dir, "gems", "rake-13.0.0")
      FileUtils.mkdir_p(File.join(rake_dir, "exe"))
      FileUtils.mkdir_p(File.join(rake_dir, "bin"))
      File.write(File.join(rake_dir, "exe", "rake"), "#!/usr/bin/env ruby")
      File.write(File.join(rake_dir, "bin", "rake"), "#!/usr/bin/env ruby")

      result = Scint::Installer::ExtensionBuilder.send(:find_rake_executable, ruby_dir)
      assert_equal File.join(rake_dir, "exe", "rake"), result
    end
  end

  def test_find_rake_executable_returns_nil_when_no_gems_dir
    with_tmpdir do |dir|
      result = Scint::Installer::ExtensionBuilder.send(:find_rake_executable, dir)
      assert_nil result
    end
  end

  def test_find_rake_executable_returns_nil_when_no_rake_installed
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby")
      FileUtils.mkdir_p(File.join(ruby_dir, "gems", "rspec-3.0.0", "exe"))

      result = Scint::Installer::ExtensionBuilder.send(:find_rake_executable, ruby_dir)
      assert_nil result
    end
  end

  def test_link_extensions_skips_when_directory_already_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      spec = fake_spec(name: "ffi", version: "1.17.0")
      abi_key = "ruby-test-arch"
      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")

      ext_install_dir = File.join(
        ruby_dir,
        "extensions",
        Scint::Platform.gem_arch,
        Scint::Platform.extension_api_version,
        "ffi-1.17.0",
      )
      FileUtils.mkdir_p(ext_install_dir)
      File.write(File.join(ext_install_dir, "marker"), "existing")

      cached_ext = File.join(dir, "cached_ext")
      FileUtils.mkdir_p(cached_ext)
      File.write(File.join(cached_ext, "ffi_ext.so"), "binary")

      # Should not raise or overwrite -- hardlink_tree not called since dir exists
      Scint::Installer::ExtensionBuilder.send(:link_extensions, cached_ext, ruby_dir, spec, abi_key)

      # Existing content preserved
      assert_equal "existing", File.read(File.join(ext_install_dir, "marker"))
      # New file not linked since directory already existed
      refute File.exist?(File.join(ext_install_dir, "ffi_ext.so"))
    end
  end

  def test_link_extensions_copies_shared_objects_into_gem_lib
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      spec = fake_spec(name: "ox", version: "2.14.23")
      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      gem_lib_dir = File.join(ruby_dir, "gems", "ox-2.14.23", "lib")
      FileUtils.mkdir_p(gem_lib_dir)

      cached_ext = File.join(dir, "cached_ext")
      FileUtils.mkdir_p(cached_ext)
      File.write(File.join(cached_ext, "ox.so"), "binary")

      Scint::Installer::ExtensionBuilder.send(:link_extensions, cached_ext, ruby_dir, spec, "ruby-test")

      ext_install_dir = File.join(
        ruby_dir,
        "extensions",
        Scint::Platform.gem_arch,
        Scint::Platform.extension_api_version,
        "ox-2.14.23",
      )
      assert File.exist?(File.join(ext_install_dir, "ox.so"))
      assert File.exist?(File.join(gem_lib_dir, "ox.so"))
    end
  end

  def test_spec_full_name_with_ruby_platform
    spec = fake_spec(name: "rack", version: "2.2.8", platform: "ruby")
    result = Scint::Installer::ExtensionBuilder.send(:spec_full_name, spec)
    assert_equal "rack-2.2.8", result
  end

  def test_spec_full_name_with_native_platform
    spec = fake_spec(name: "ffi", version: "1.17.0", platform: "x86_64-linux")
    result = Scint::Installer::ExtensionBuilder.send(:spec_full_name, spec)
    assert_equal "ffi-1.17.0-x86_64-linux", result
  end

  def test_spec_full_name_with_empty_platform
    spec = fake_spec(name: "rack", version: "2.2.8", platform: "")
    result = Scint::Installer::ExtensionBuilder.send(:spec_full_name, spec)
    assert_equal "rack-2.2.8", result
  end

  def test_spec_full_name_with_nil_platform
    spec = Struct.new(:name, :version, keyword_init: true).new(name: "rack", version: "2.2.8")
    result = Scint::Installer::ExtensionBuilder.send(:spec_full_name, spec)
    assert_equal "rack-2.2.8", result
  end

  def test_compile_cmake_invokes_cmake_commands
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(env, *cmd, **opts) { calls << cmd }) do
      Scint::Installer::ExtensionBuilder.send(
        :compile_cmake,
        "/tmp/ext",
        "/tmp/build",
        "/tmp/install",
        {},
        4,
      )
    end

    assert_equal 3, calls.size
    assert_includes calls[0], "cmake"
    assert_includes calls[0], "-B"
    assert_includes calls[1], "--build"
    assert_includes calls[1], "4"
    assert_includes calls[2], "--install"
  end

  def test_compile_rake_without_found_rake_executable
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(env, *cmd, **opts) { calls << cmd }) do
      with_tmpdir do |dir|
        ext_dir = File.join(dir, "ext")
        FileUtils.mkdir_p(ext_dir)

        Scint::Installer::ExtensionBuilder.send(
          :compile_rake,
          ext_dir,
          "/tmp/build",
          "/tmp/install",
          "/tmp/ruby",
          {},
        )
      end
    end

    # Without a found rake_exe, it uses ruby -S rake
    assert_equal 1, calls.size
    assert_includes calls[0], "-S"
    assert_includes calls[0], "rake"
  end

  def test_compile_rake_with_found_rake_executable
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(env, *cmd, **opts) { calls << cmd }) do
      with_tmpdir do |dir|
        ext_dir = File.join(dir, "ext")
        FileUtils.mkdir_p(ext_dir)

        # Set up a ruby_dir with a rake executable so find_rake_executable returns a path
        ruby_dir = File.join(dir, "ruby")
        rake_exe_dir = File.join(ruby_dir, "gems", "rake-13.2.1", "exe")
        FileUtils.mkdir_p(rake_exe_dir)
        File.write(File.join(rake_exe_dir, "rake"), "#!/usr/bin/env ruby\n")

        Scint::Installer::ExtensionBuilder.send(
          :compile_rake,
          ext_dir,
          "/tmp/build",
          "/tmp/install",
          ruby_dir,
          {},
        )
      end
    end

    # With a found rake_exe, it uses ruby <rake_exe_path> compile (line 174)
    assert_equal 1, calls.size
    assert_includes calls[0].last, "compile"
    # Should NOT include -S rake since the rake executable was found
    refute_includes calls[0], "-S"
    # Should include the rake executable path
    assert calls[0].any? { |arg| arg.include?("rake-13.2.1") }, "should use found rake executable path"
  end

  def test_compile_rake_copies_shared_objects
    with_tmpdir do |dir|
      ext_dir = File.join(dir, "ext")
      install_dir = File.join(dir, "install")
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(install_dir)

      # Simulate a built .so file in ext dir
      File.write(File.join(ext_dir, "native.so"), "binary")

      # Stub run_cmd to not actually run anything
      Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(*_args, **_opts) { nil }) do
        Scint::Installer::ExtensionBuilder.send(
          :compile_rake,
          ext_dir,
          "/tmp/build",
          install_dir,
          "/tmp/ruby",
          {},
        )
      end

      assert File.exist?(File.join(install_dir, "native.so"))
    end
  end

  def test_run_cmd_debug_mode_uses_process_spawn
    with_tmpdir do |dir|
      with_env("SCINT_DEBUG", "1") do
        Scint::Installer::ExtensionBuilder.send(
          :run_cmd,
          {},
          RbConfig.ruby,
          "-e",
          "exit 0",
        )
      end
    end
  end

  def test_run_cmd_debug_mode_raises_on_failure
    with_env("SCINT_DEBUG", "1") do
      error = assert_raises(Scint::ExtensionBuildError) do
        Scint::Installer::ExtensionBuilder.send(
          :run_cmd,
          {},
          RbConfig.ruby,
          "-e",
          "exit 1",
        )
      end

      assert_includes error.message, "exit 1"
    end
  end
end
