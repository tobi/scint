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

  # --- help subcommand ---

  def test_help_prints_usage
    out, _err = with_captured_io do
      status = Scint::CLI::Cache.new(["help"]).run
      assert_equal 0, status
    end
    assert_includes out, "Manage scint's cache"
    assert_includes out, "Commands:"
  end

  def test_help_flag
    out, _err = with_captured_io do
      status = Scint::CLI::Cache.new(["-h"]).run
      assert_equal 0, status
    end
    assert_includes out, "Manage scint's cache"
  end

  # --- clean with no cache dir ---

  def test_clean_when_cache_dir_missing
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["clean"]).run
          assert_equal 0, status
        end
        assert_includes out, "No cache to clear"
      end
    end
  end

  # --- clean with package names (clear_packages) ---

  def test_clean_with_package_names_removes_matching
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "scint")
        inbound_gems = File.join(root, "inbound", "gems")
        abi = Scint::Platform.abi_key
        cached_abi = File.join(root, "cached", abi)

        FileUtils.mkdir_p(inbound_gems)
        FileUtils.mkdir_p(cached_abi)

        File.write(File.join(inbound_gems, "rack-3.0.0.gem"), "data")
        File.write(File.join(inbound_gems, "puma-6.0.0.gem"), "data")
        FileUtils.mkdir_p(File.join(cached_abi, "rack-3.0.0"))
        File.write(File.join(cached_abi, "rack-3.0.0.spec.marshal"), "data")

        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["clean", "rack"]).run
          assert_equal 0, status
        end

        assert_includes out, "Removed 3 entries matching: rack"
        # puma should remain
        assert_includes Dir.children(inbound_gems), "puma-6.0.0.gem"
        refute_includes Dir.children(inbound_gems), "rack-3.0.0.gem"
      end
    end
  end

  def test_clean_with_package_names_skips_missing_subdirs
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        root = File.join(dir, "scint")
        FileUtils.mkdir_p(root)
        # No subdirs at all

        out, _err = with_captured_io do
          status = Scint::CLI::Cache.new(["clean", "rack"]).run
          assert_equal 0, status
        end

        assert_includes out, "Removed 0 entries"
      end
    end
  end

  # --- format_size ---

  def test_format_size_bytes
    cli = Scint::CLI::Cache.new([])
    assert_equal "512 B", cli.send(:format_size, 512)
  end

  def test_format_size_kib
    cli = Scint::CLI::Cache.new([])
    assert_equal "1.5 KiB", cli.send(:format_size, 1536)
  end

  def test_format_size_mib
    cli = Scint::CLI::Cache.new([])
    assert_equal "2.0 MiB", cli.send(:format_size, 2 * 1024 * 1024)
  end

  def test_format_size_gib
    cli = Scint::CLI::Cache.new([])
    assert_equal "1.0 GiB", cli.send(:format_size, 1024 * 1024 * 1024)
  end

  # --- parse_add_options ---

  def test_parse_add_options_gems
    cli = Scint::CLI::Cache.new(["add", "rack", "puma"])
    cli.instance_variable_get(:@argv).shift # consume "add"
    opts = cli.send(:parse_add_options)
    assert_equal ["rack", "puma"], opts[:gems]
    assert_equal false, opts[:force]
    assert_nil opts[:lockfile]
    assert_nil opts[:gemfile]
  end

  def test_parse_add_options_lockfile
    cli = Scint::CLI::Cache.new(["add", "--lockfile", "Gemfile.lock"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal "Gemfile.lock", opts[:lockfile]
  end

  def test_parse_add_options_gemfile
    cli = Scint::CLI::Cache.new(["add", "--gemfile", "Gemfile"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal "Gemfile", opts[:gemfile]
  end

  def test_parse_add_options_jobs
    cli = Scint::CLI::Cache.new(["add", "-j", "4", "rack"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal 4, opts[:jobs]
    assert_equal ["rack"], opts[:gems]
  end

  def test_parse_add_options_force
    cli = Scint::CLI::Cache.new(["add", "--force", "rack"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal true, opts[:force]
  end

  def test_parse_add_options_force_short
    cli = Scint::CLI::Cache.new(["add", "-f", "rack"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal true, opts[:force]
  end

  def test_parse_add_options_version
    cli = Scint::CLI::Cache.new(["add", "--version", "~> 3.0", "rack"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal "~> 3.0", opts[:version]
  end

  def test_parse_add_options_source
    cli = Scint::CLI::Cache.new(["add", "--source", "https://private.example.com/", "rack"])
    cli.instance_variable_get(:@argv).shift
    opts = cli.send(:parse_add_options)
    assert_equal "https://private.example.com/", opts[:source]
  end

  def test_parse_add_options_unknown_flag_raises
    cli = Scint::CLI::Cache.new(["add", "--bogus"])
    cli.instance_variable_get(:@argv).shift
    assert_raises(Scint::CacheError) do
      cli.send(:parse_add_options)
    end
  end

  # --- collect_specs_for_add with lockfile ---

  def test_collect_specs_for_add_with_lockfile
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.0.0")

    fake_lockfile = Object.new
    fake_lockfile.define_singleton_method(:sources) { [] }

    fake_install = Object.new
    fake_install.define_singleton_method(:lockfile_to_resolved) { |_| [spec] }
    fake_install.instance_variable_set(:@credentials, nil)

    options = {
      lockfile: "Gemfile.lock",
      gemfile: nil,
      gems: [],
      credentials: Scint::Credentials.new,
    }

    Scint::Lockfile::Parser.stub(:parse, fake_lockfile) do
      Scint::CLI::Install.stub(:new, fake_install) do
        result = cli.send(:collect_specs_for_add, options)
        assert_equal 1, result.size
        assert_equal "rack", result.first.name
      end
    end
  end

  # --- collect_specs_for_add with gems (resolve_from_names) ---

  def test_collect_specs_for_add_with_gem_names
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.0.0")

    fake_install = Object.new
    fake_install.instance_variable_set(:@credentials, nil)

    options = {
      lockfile: nil,
      gemfile: nil,
      gems: ["rack"],
      version: nil,
      source: "https://rubygems.org",
      credentials: Scint::Credentials.new,
    }

    cli.stub(:resolve_from_names, ->(_, _) { [spec] }) do
      Scint::CLI::Install.stub(:new, fake_install) do
        result = cli.send(:collect_specs_for_add, options)
        assert_equal 1, result.size
        assert_equal "rack", result.first.name
      end
    end
  end

  # --- collect_specs_for_add with gemfile ---

  def test_collect_specs_for_add_with_gemfile
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rails", version: "7.0.0")

    fake_install = Object.new
    fake_install.instance_variable_set(:@credentials, nil)

    options = {
      lockfile: nil,
      gemfile: "Gemfile",
      gems: [],
      credentials: Scint::Credentials.new,
    }

    cli.stub(:resolve_from_gemfile, ->(_, _, _) { [spec] }) do
      Scint::CLI::Install.stub(:new, fake_install) do
        result = cli.send(:collect_specs_for_add, options)
        assert_equal 1, result.size
        assert_equal "rails", result.first.name
      end
    end
  end

  # --- dedupe_specs ---

  def test_dedupe_specs_removes_duplicates
    cli = Scint::CLI::Cache.new([])
    spec1 = fake_spec(name: "rack", version: "3.0.0")
    spec2 = fake_spec(name: "rack", version: "3.0.0")
    spec3 = fake_spec(name: "puma", version: "6.0.0")

    result = cli.send(:dedupe_specs, [spec1, spec2, spec3])
    assert_equal 2, result.size
    names = result.map(&:name).sort
    assert_equal ["puma", "rack"], names
  end

  # --- resolve_from_names builds dependencies and calls resolve ---

  def test_resolve_from_names_creates_deps_and_resolves
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.0.0")

    fake_install = Object.new
    captured_gemfile = nil
    fake_install.define_singleton_method(:resolve) do |gemfile, lockfile, cache|
      captured_gemfile = gemfile
      [spec]
    end
    fake_install.instance_variable_set(:@credentials, nil)

    options = {
      gems: ["rack"],
      version: "~> 3.0",
      source: "https://rubygems.org",
      credentials: Scint::Credentials.new,
    }

    result = cli.send(:resolve_from_names, fake_install, options)
    assert_equal [spec], result
    assert_equal 1, captured_gemfile.dependencies.size
    assert_equal "rack", captured_gemfile.dependencies.first.name
    assert_equal ["~> 3.0"], captured_gemfile.dependencies.first.version_reqs
  end

  def test_resolve_from_names_uses_default_version_req
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "puma", version: "6.0.0")

    fake_install = Object.new
    captured_gemfile = nil
    fake_install.define_singleton_method(:resolve) do |gemfile, lockfile, cache|
      captured_gemfile = gemfile
      [spec]
    end
    fake_install.instance_variable_set(:@credentials, nil)

    options = {
      gems: ["puma"],
      version: nil,
      source: "https://rubygems.org",
      credentials: Scint::Credentials.new,
    }

    result = cli.send(:resolve_from_names, fake_install, options)
    assert_equal [spec], result
    assert_equal [">= 0"], captured_gemfile.dependencies.first.version_reqs
  end

  # --- resolve_from_gemfile ---

  def test_resolve_from_gemfile_without_lockfile
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.0.0")

    fake_gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )

    fake_install = Object.new
    fake_install.define_singleton_method(:resolve) { |_gf, _lf, _cache| [spec] }

    creds = Scint::Credentials.new

    with_tmpdir do |dir|
      gemfile_path = File.join(dir, "Gemfile")
      File.write(gemfile_path, "")
      # No Gemfile.lock exists

      Scint::Gemfile::Parser.stub(:parse, fake_gemfile) do
        result = cli.send(:resolve_from_gemfile, fake_install, gemfile_path, creds)
        assert_equal [spec], result
      end
    end
  end

  def test_resolve_from_gemfile_with_current_lockfile
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.0.0")

    fake_gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )

    fake_lockfile = Object.new
    fake_lockfile.define_singleton_method(:sources) { [] }

    fake_install = Object.new
    fake_install.define_singleton_method(:lockfile_current?) { |_gf, _lf| true }
    fake_install.define_singleton_method(:lockfile_to_resolved) { |_lf| [spec] }

    creds = Scint::Credentials.new

    with_tmpdir do |dir|
      gemfile_path = File.join(dir, "Gemfile")
      lockfile_path = File.join(dir, "Gemfile.lock")
      File.write(gemfile_path, "")
      File.write(lockfile_path, "")

      Scint::Gemfile::Parser.stub(:parse, fake_gemfile) do
        Scint::Lockfile::Parser.stub(:parse, fake_lockfile) do
          result = cli.send(:resolve_from_gemfile, fake_install, gemfile_path, creds)
          assert_equal [spec], result
        end
      end
    end
  end

  def test_resolve_from_gemfile_with_stale_lockfile
    cli = Scint::CLI::Cache.new([])
    spec = fake_spec(name: "rack", version: "3.1.0")

    fake_gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )

    fake_lockfile = Object.new
    fake_lockfile.define_singleton_method(:sources) { [] }

    fake_install = Object.new
    fake_install.define_singleton_method(:lockfile_current?) { |_gf, _lf| false }
    fake_install.define_singleton_method(:resolve) { |_gf, _lf, _cache| [spec] }

    creds = Scint::Credentials.new

    with_tmpdir do |dir|
      gemfile_path = File.join(dir, "Gemfile")
      lockfile_path = File.join(dir, "Gemfile.lock")
      File.write(gemfile_path, "")
      File.write(lockfile_path, "")

      Scint::Gemfile::Parser.stub(:parse, fake_gemfile) do
        Scint::Lockfile::Parser.stub(:parse, fake_lockfile) do
          result = cli.send(:resolve_from_gemfile, fake_install, gemfile_path, creds)
          assert_equal [spec], result
          assert_equal "3.1.0", result.first.version
        end
      end
    end
  end
end
