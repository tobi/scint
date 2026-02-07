# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/installer/planner"
require "bundler2/cache/layout"

class PlannerTest < Minitest::Test
  Spec = Struct.new(:name, :version, :platform, :has_extensions, :size, keyword_init: true)

  def test_plan_one_marks_skip_when_already_installed
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Bundler2::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      gem_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "gems", "rack-2.2.8")
      FileUtils.mkdir_p(gem_dir)

      entry = Bundler2::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :skip, entry.action
      assert_equal gem_dir, entry.gem_path
    end
  end

  def test_plan_one_marks_link_when_extracted_cache_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Bundler2::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      FileUtils.mkdir_p(layout.extracted_path(spec))

      entry = Bundler2::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
      assert_equal layout.extracted_path(spec), entry.cached_path
    end
  end

  def test_plan_one_marks_build_ext_when_extensions_missing
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Bundler2::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      FileUtils.mkdir_p(layout.extracted_path(spec))

      entry = Bundler2::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_link_when_extensions_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Bundler2::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      FileUtils.mkdir_p(layout.extracted_path(spec))
      FileUtils.mkdir_p(layout.ext_path(spec))

      entry = Bundler2::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_sorts_downloads_by_estimated_size_before_rest
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Bundler2::Cache::Layout.new(root: File.join(dir, "cache"))

      big = Spec.new(name: "big", version: "1.0.0", platform: "ruby", has_extensions: false, size: 50)
      small = Spec.new(name: "small", version: "1.0.0", platform: "ruby", has_extensions: false, size: 10)
      cached = Spec.new(name: "cached", version: "1.0.0", platform: "ruby", has_extensions: false, size: 100)

      FileUtils.mkdir_p(layout.extracted_path(cached))

      entries = Bundler2::Installer::Planner.plan([small, cached, big], bundle_path, layout)

      assert_equal %i[download download link], entries.map(&:action)
      assert_equal ["big", "small", "cached"], entries.map { |e| e.spec.name }
    end
  end
end
