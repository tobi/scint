# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/cli/cache"

class CLICacheTest < Minitest::Test
  def with_captured_io
    old_out = $stdout
    old_err = $stderr
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    yield
    [out.string, err.string]
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  def test_dir_prints_cache_path
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        out, err = with_captured_io do
          status = Bundler2::CLI::Cache.new(["dir"]).run
          assert_equal 0, status
        end

        assert_equal "", err
        assert_equal File.join(dir, "bundler2") + "\n", out
      end
    end
  end

  def test_list_prints_empty_message_when_cache_missing
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        out, _err = with_captured_io do
          status = Bundler2::CLI::Cache.new(["list"]).run
          assert_equal 0, status
        end

        assert_equal "(cache is empty)\n", out
      end
    end
  end

  def test_list_shows_entries
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "bundler2")
        inbound = File.join(root, "inbound")
        marker = File.join(root, "marker.txt")

        FileUtils.mkdir_p(inbound)
        File.write(File.join(inbound, "rack-2.2.8.gem"), "gem")
        File.write(marker, "x")

        out, _err = with_captured_io do
          status = Bundler2::CLI::Cache.new(["list"]).run
          assert_equal 0, status
        end

        assert_includes out, "inbound"
        assert_includes out, "marker.txt"
        assert_includes out, root
      end
    end
  end

  def test_clear_removes_entries
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "bundler2")
        FileUtils.mkdir_p(File.join(root, "extracted"))
        File.write(File.join(root, "extracted", "x"), "1")

        out, _err = with_captured_io do
          status = Bundler2::CLI::Cache.new(["clear"]).run
          assert_equal 0, status
        end

        assert_equal [], Dir.children(root)
        assert_includes out, "Cleared cache: #{root}"
      end
    end
  end

  def test_unknown_subcommand_exits_with_error
    out, err = with_captured_io do
      status = Bundler2::CLI::Cache.new(["wat"]).run
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Unknown cache subcommand"
  end
end
