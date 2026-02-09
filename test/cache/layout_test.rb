# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/layout"

class CacheLayoutTest < Minitest::Test
  def setup
    Scint.cache_root = nil if Scint.respond_to?(:cache_root=)
  end

  def teardown
    Scint.cache_root = nil if Scint.respond_to?(:cache_root=)
  end

  def test_default_root_uses_xdg_cache_home
    with_tmpdir do |dir|
      with_env("SCINT_CACHE", nil) do
        with_env("XDG_CACHE_HOME", dir) do
          Scint.cache_root = nil
          layout = Scint::Cache::Layout.new
          assert_equal File.join(dir, "scint"), layout.root
        end
      end
    end
  end

  def test_default_root_uses_scint_cache_when_set
    with_tmpdir do |dir|
      cache_root = File.join(dir, "custom-scint-cache")
      with_env("SCINT_CACHE", cache_root) do
        with_env("XDG_CACHE_HOME", File.join(dir, "xdg-cache")) do
          Scint.cache_root = nil
          layout = Scint::Cache::Layout.new
          assert_equal cache_root, layout.root
        end
      end
    end
  end

  def test_full_name_omits_ruby_platform
    layout = Scint::Cache::Layout.new(root: "/tmp/x")
    spec = fake_spec(name: "rack", version: "2.2.8", platform: "ruby")

    assert_equal "rack-2.2.8", layout.full_name(spec)
  end

  def test_full_name_includes_non_ruby_platform
    layout = Scint::Cache::Layout.new(root: "/tmp/x")
    spec = fake_spec(name: "nokogiri", version: "1.17.0", platform: "x86_64-linux")

    assert_equal "nokogiri-1.17.0-x86_64-linux", layout.full_name(spec)
  end

  def test_full_name_accepts_hash_like_spec
    layout = Scint::Cache::Layout.new(root: "/tmp/x")
    spec = { name: "rack", version: "2.2.8", platform: "ruby" }

    assert_equal "rack-2.2.8", layout.full_name(spec)
  end

  def test_index_path_prefers_source_cache_slug
    source = Struct.new(:cache_slug).new("custom-slug")
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")

    assert_equal "/tmp/cache/index/custom-slug", layout.index_path(source)
  end

  def test_index_path_slugifies_uri
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")

    assert_equal "/tmp/cache/index/rubygems.orgapi-v1", layout.index_path("https://rubygems.org/api/v1")
  end

  def test_index_path_hashes_invalid_uri
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    path = layout.index_path("@@@not a uri@@@")

    assert_match %r{/tmp/cache/index/[0-9a-f]{16}$}, path
  end

  def test_git_path_is_stable
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    path = layout.git_path("https://github.com/ruby/ruby.git")

    assert_match %r{/tmp/cache/inbound/gits/[0-9a-f]{16}$}, path
  end

  def test_git_path_normalizes_uri_objects
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    uri = URI.parse("https://github.com/ruby/ruby.git")

    assert_equal layout.git_path(uri), layout.git_path(uri.to_s)
  end

  def test_git_checkout_path_scopes_by_revision
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    path = layout.git_checkout_path("https://github.com/ruby/ruby.git", "abc123")

    assert_equal "/tmp/cache/inbound/gits/#{File.basename(layout.git_path("https://github.com/ruby/ruby.git"))}/checkouts/abc123", path
  end

  def test_install_ruby_dir_is_under_install_env
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")

    assert_equal "/tmp/cache/install-env", layout.install_env_dir
    assert_equal "/tmp/cache/install-env/ruby/#{RUBY_VERSION.split(".")[0, 2].join(".")}.0", layout.install_ruby_dir
  end

  def test_ensure_dir_makes_directory_once_even_with_threads
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: dir)
      target = File.join(dir, "index", "rubygems")

      calls = 0
      original = Scint::FS.method(:mkdir_p)

      Scint::FS.stub(:mkdir_p, lambda { |path|
        calls += 1
        original.call(path)
      }) do
        threads = 10.times.map do
          Thread.new { layout.ensure_dir(target) }
        end
        threads.each(&:join)
      end

      assert Dir.exist?(target)
      assert_equal 1, calls
    end
  end
end
