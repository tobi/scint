# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cli/cache"
require "scint/cache/prewarm"

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
          status = Scint::CLI::Cache.new(["dir"]).run
          assert_equal 0, status
        end

        assert_equal "", err
        assert_equal File.join(dir, "scint") + "\n", out
      end
    end
  end

  def test_size_prints_empty_message_when_cache_missing
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["size"]).run
          assert_equal 0, status
        end

        assert_equal "0 B (cache is empty)\n", out
      end
    end
  end

  def test_size_shows_subdir_breakdown
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "scint")
        inbound = File.join(root, "inbound")

        FileUtils.mkdir_p(inbound)
        File.write(File.join(inbound, "rack-2.2.8.gem"), "gem")

        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["size"]).run
          assert_equal 0, status
        end

        assert_includes out, "inbound"
        assert_includes out, "total"
      end
    end
  end

  def test_clear_removes_entries
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "scint")
        FileUtils.mkdir_p(File.join(root, "extracted"))
        File.write(File.join(root, "extracted", "x"), "1")

        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["clear"]).run
          assert_equal 0, status
        end

        assert_equal [], Dir.children(root)
        assert_includes out, "Cleared 1 entries from #{root}"
      end
    end
  end

  def test_unknown_subcommand_exits_with_error
    out, err = with_captured_io do
      status = Scint::CLI::Cache.new(["wat"]).run
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Unknown cache subcommand"
  end

  def test_add_requires_inputs
    out, err = with_captured_io do
      status = Scint::CLI::Cache.new(["add"]).run
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Usage: scint cache add"
  end

  def test_add_runs_prewarm_and_prints_summary
    cli = Scint::CLI::Cache.new(["add", "rack"])
    spec = fake_spec(name: "rack", version: "2.2.8")

    captured_specs = nil
    fake_prewarm = Object.new
    fake_prewarm.define_singleton_method(:run) do |specs|
      captured_specs = specs
      { warmed: 1, skipped: 0, ignored: 0, failed: 0, failures: [] }
    end

    cli.stub(:collect_specs_for_add, [spec]) do
      Scint::Cache::Prewarm.stub(:new, ->(**_) { fake_prewarm }) do
        out, err = with_captured_io do
          status = cli.run
          assert_equal 0, status
        end

        assert_equal "", err
        assert_includes out, "Cache add complete: 1 warmed"
      end
    end

    assert_equal [spec], captured_specs
  end

  def test_add_returns_failure_when_prewarm_reports_errors
    cli = Scint::CLI::Cache.new(["add", "rack"])
    spec = fake_spec(name: "rack", version: "2.2.8")

    fake_prewarm = Object.new
    fake_prewarm.define_singleton_method(:run) do |_specs|
      err = Scint::CacheError.new("boom")
      { warmed: 0, skipped: 0, ignored: 0, failed: 1, failures: [{ spec: spec, error: err }] }
    end

    cli.stub(:collect_specs_for_add, [spec]) do
      Scint::Cache::Prewarm.stub(:new, ->(**_) { fake_prewarm }) do
        out, err = with_captured_io do
          status = cli.run
          assert_equal 1, status
        end

        assert_includes err, "Cache prewarm failed"
        assert_includes out, "Cache add: 0 warmed"
      end
    end
  end
end
