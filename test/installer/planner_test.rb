# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/planner"
require "scint/cache/layout"

class PlannerTest < Minitest::Test
  Spec = Struct.new(:name, :version, :platform, :has_extensions, :size, :source, keyword_init: true)

  def test_plan_one_marks_skip_when_already_installed
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      gem_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "gems", "rack-2.2.8")
      spec_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "rack-2.2.8.gemspec"), "Gem::Specification.new do |s| end\n")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :skip, entry.action
      assert_equal gem_dir, entry.gem_path
    end
  end

  def test_plan_one_marks_build_ext_when_installed_but_extension_link_missing
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "bootsnap", version: "1.22.0", platform: "ruby", has_extensions: false)

      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      gem_dir = File.join(ruby_dir, "gems", "bootsnap-1.22.0")
      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "bootsnap-1.22.0.gemspec"), "Gem::Specification.new do |s| end\n")

      ext_src = File.join(layout.extracted_path(spec), "ext", "bootsnap")
      FileUtils.mkdir_p(ext_src)
      File.write(File.join(ext_src, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_does_not_skip_when_gemspec_missing
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      gem_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "gems", "rack-2.2.8")
      FileUtils.mkdir_p(gem_dir)

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      refute_equal :skip, entry.action
    end
  end

  def test_plan_one_marks_link_when_extracted_cache_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      FileUtils.mkdir_p(layout.extracted_path(spec))

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
      assert_equal layout.extracted_path(spec), entry.cached_path
    end
  end

  def test_plan_one_marks_link_when_no_ext_directory_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      FileUtils.mkdir_p(layout.extracted_path(spec))

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_one_marks_build_ext_when_ext_directory_exists_and_not_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_build_ext_when_extensions_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
      FileUtils.mkdir_p(layout.ext_path(spec))

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_build_ext_when_native_dir_exists_even_if_flag_false
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "bootsnap", version: "1.22.0", platform: "ruby", has_extensions: false)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "bootsnap")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_sorts_downloads_by_estimated_size_before_rest
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))

      big = Spec.new(name: "big", version: "1.0.0", platform: "ruby", has_extensions: false, size: 50)
      small = Spec.new(name: "small", version: "1.0.0", platform: "ruby", has_extensions: false, size: 10)
      cached = Spec.new(name: "cached", version: "1.0.0", platform: "ruby", has_extensions: false, size: 100)

      FileUtils.mkdir_p(layout.extracted_path(cached))

      entries = Scint::Installer::Planner.plan([small, cached, big], bundle_path, layout)

      assert_equal %i[download download link], entries.map(&:action)
      assert_equal ["big", "small", "cached"], entries.map { |e| e.spec.name }
    end
  end

  def test_plan_one_marks_link_for_relative_local_path_source
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "components", "crm")
        FileUtils.mkdir_p(local_dir)

        spec = Spec.new(
          name: "crm",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: "components/crm",
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :link, entry.action
        assert_equal File.realpath(local_dir), File.realpath(entry.cached_path)
      end
    end
  end

  def test_plan_one_marks_build_ext_for_relative_local_path_source_with_extconf
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "components", "native")
        ext_dir = File.join(local_dir, "ext", "native")
        FileUtils.mkdir_p(ext_dir)
        File.write(File.join(ext_dir, "extconf.rb"), "")

        spec = Spec.new(
          name: "native",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: "components/native",
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :build_ext, entry.action
        assert_equal File.realpath(local_dir), File.realpath(entry.cached_path)
      end
    end
  end
end
