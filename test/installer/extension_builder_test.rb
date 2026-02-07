# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/extension_builder"
require "scint/cache/layout"

class ExtensionBuilderTest < Minitest::Test
  Prepared = Struct.new(:spec, :extracted_path, :gemspec, :from_cache, keyword_init: true)

  def test_build_reuses_cached_extensions_without_compiling
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")
      prepared = Prepared.new(spec: spec, extracted_path: File.join(dir, "src"), gemspec: nil, from_cache: true)

      abi_key = "ruby-test-arch"
      cached_ext = layout.ext_path(spec, abi_key)
      FileUtils.mkdir_p(cached_ext)
      File.write(File.join(cached_ext, "ffi_ext.so"), "bin")
      File.write(File.join(cached_ext, "gem.build_complete"), "")

      Scint::Installer::ExtensionBuilder.stub(:find_extension_dirs, ->(_src) { raise "should not run" }) do
        assert Scint::Installer::ExtensionBuilder.build(prepared, bundle_path, layout, abi_key: abi_key)
      end

      linked = File.join(
        ruby_bundle_dir(bundle_path),
        "extensions",
        Scint::Platform.gem_arch,
        Scint::Platform.extension_api_version,
        "ffi-1.17.0",
        "ffi_ext.so",
      )

      assert File.exist?(linked)
      assert_hardlinked(File.join(cached_ext, "ffi_ext.so"), linked)
    end
  end

  def test_cached_build_available_checks_marker
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")
      abi_key = "ruby-test-arch"
      cached_ext = layout.ext_path(spec, abi_key)
      FileUtils.mkdir_p(cached_ext)

      assert_equal false, Scint::Installer::ExtensionBuilder.cached_build_available?(spec, layout, abi_key: abi_key)

      File.write(File.join(cached_ext, "gem.build_complete"), "")
      assert_equal true, Scint::Installer::ExtensionBuilder.cached_build_available?(spec, layout, abi_key: abi_key)
    end
  end

  def test_link_cached_build_links_without_compiling
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "ffi", version: "1.17.0")
      prepared = Prepared.new(spec: spec, extracted_path: File.join(dir, "src"), gemspec: nil, from_cache: true)
      abi_key = "ruby-test-arch"

      cached_ext = layout.ext_path(spec, abi_key)
      FileUtils.mkdir_p(cached_ext)
      File.write(File.join(cached_ext, "ffi_ext.so"), "bin")
      File.write(File.join(cached_ext, "gem.build_complete"), "")

      assert_equal true, Scint::Installer::ExtensionBuilder.link_cached_build(prepared, bundle_path, layout, abi_key: abi_key)

      linked = File.join(
        ruby_bundle_dir(bundle_path),
        "extensions",
        Scint::Platform.gem_arch,
        Scint::Platform.extension_api_version,
        "ffi-1.17.0",
        "ffi_ext.so",
      )
      assert File.exist?(linked)
      assert_hardlinked(File.join(cached_ext, "ffi_ext.so"), linked)
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
    calls = []
    Scint::Installer::ExtensionBuilder.stub(:run_cmd, ->(env, *cmd, **opts) { calls << { env: env, cmd: cmd, opts: opts } }) do
      Scint::Installer::ExtensionBuilder.send(
        :compile_extconf,
        "/tmp/ext",
        "/tmp/build",
        "/tmp/install",
        { "MAKEFLAGS" => "-j5" },
        5,
      )
    end

    assert_equal 3, calls.size
    assert_equal ["make", "-j5", "-C", "/tmp/build"], calls[1][:cmd]
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
end
