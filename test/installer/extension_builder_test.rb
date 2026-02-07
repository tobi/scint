# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/extension_builder"
require "scint/cache/layout"

class ExtensionBuilderTest < Minitest::Test
  Prepared = Struct.new(:spec, :extracted_path, :gemspec, :from_cache, keyword_init: true)

  def test_build_reuses_cached_extensions_without_compiling
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".scint")
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

  def test_build_raises_when_no_extension_directories_exist
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".scint")
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
    env = Scint::Installer::ExtensionBuilder.send(:build_env, "/tmp/src", "/tmp/.scint/ruby/3.4.0")

    assert env.key?("MAKEFLAGS")
    assert env.key?("CFLAGS")
    assert_equal "/tmp/.scint/ruby/3.4.0", env["GEM_HOME"]
    assert_equal "/tmp/.scint/ruby/3.4.0", env["GEM_PATH"]
  end

  def test_buildable_source_dir_false_for_non_native_ext_tree
    with_tmpdir do |dir|
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p(File.join(gem_dir, "ext", "concurrent-ruby"))
      File.write(File.join(gem_dir, "ext", "concurrent-ruby", "ConcurrentRubyService.java"), "")

      assert_equal false, Scint::Installer::ExtensionBuilder.buildable_source_dir?(gem_dir)
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
end
