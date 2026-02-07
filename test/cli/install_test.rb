# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cli/install"
require "scint/cache/layout"
require "scint/source/rubygems"

class CLIInstallTest < Minitest::Test
  class FakeScheduler
    attr_reader :enqueued

    def initialize
      @enqueued = []
    end

    def enqueue(type, name, payload = nil, depends_on: [], follow_up: nil)
      @enqueued << { type: type, name: name, payload: payload }
      @enqueued.size
    end

    def wait_for(_type)
      nil
    end
  end

  def with_captured_stderr
    old_err = $stderr
    err = StringIO.new
    $stderr = err
    yield err
  ensure
    $stderr = old_err
  end

  def test_load_gemspec_uses_cached_spec_without_evaluating_extracted_gemspec
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "rack", version: "2.2.8")

      cached = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.authors = ["a"]
        s.summary = "rack"
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(cached))

      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rack.rb"), "")
      File.write(File.join(extracted, "rack.gemspec"), "raise 'should not evaluate'\n")

      gemspec = install.send(:load_gemspec, extracted, spec, cache)
      assert_equal "rack", gemspec.name
      assert_equal Gem::Version.new("2.2.8"), gemspec.version
    end
  end

  def test_load_gemspec_falls_back_to_inbound_metadata
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "demo", version: "1.0.0")

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "demo", version: "1.0.0", files: { "lib/demo.rb" => "module Demo; end\n" })

      gemspec = install.send(:load_gemspec, cache.extracted_path(spec), spec, cache)
      assert_equal "demo", gemspec.name
      assert_equal Gem::Version.new("1.0.0"), gemspec.version
    end
  end

  def test_load_gemspec_refreshes_stale_cached_require_paths_from_inbound
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "concurrent-ruby", version: "1.3.6")

      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib", "concurrent-ruby"))

      stale = Gem::Specification.new do |s|
        s.name = "concurrent-ruby"
        s.version = Gem::Version.new("1.3.6")
        s.authors = ["a"]
        s.summary = "stale"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(stale))

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(
        inbound,
        name: "concurrent-ruby",
        version: "1.3.6",
        require_paths: ["lib/concurrent-ruby"],
        files: { "lib/concurrent-ruby/concurrent.rb" => "module Concurrent; end\n" },
      )

      gemspec = install.send(:load_gemspec, extracted, spec, cache)
      assert_equal ["lib/concurrent-ruby"], gemspec.require_paths

      refreshed = install.send(:load_cached_gemspec, spec, cache, extracted)
      assert_equal ["lib/concurrent-ruby"], refreshed.require_paths
    end
  end

  def test_enqueue_link_after_download_always_enqueues_link
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new

      spec = fake_spec(name: "ffi", version: "1.17.0", has_extensions: true)
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      install.send(:enqueue_link_after_download, scheduler, entry, cache, File.join(dir, ".bundle"))
      assert_equal :link, scheduler.enqueued.last[:type]
    end
  end

  def test_enqueue_builds_only_for_native_buildable_entries
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new

      native = fake_spec(name: "ffi", version: "1.17.0", has_extensions: true)
      java_only = fake_spec(name: "concurrent-ruby", version: "1.3.6", has_extensions: true)

      native_entry = Scint::PlanEntry.new(spec: native, action: :build_ext, cached_path: nil, gem_path: nil)
      java_entry = Scint::PlanEntry.new(spec: java_only, action: :build_ext, cached_path: nil, gem_path: nil)

      ext_dir = File.join(cache.extracted_path(native), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      java_ext = File.join(cache.extracted_path(java_only), "ext", "concurrent-ruby")
      FileUtils.mkdir_p(java_ext)
      File.write(File.join(java_ext, "ConcurrentRubyService.java"), "")

      install.send(:enqueue_builds, scheduler, [native_entry, java_entry], cache, File.join(dir, ".bundle"))

      types = scheduler.enqueued.map { |e| [e[:type], e[:name]] }
      assert_includes types, [:build_ext, "ffi"]
      refute_includes types, [:build_ext, "concurrent-ruby"]
    end
  end

  def test_format_elapsed_uses_ms_for_short_durations
    install = Scint::CLI::Install.new([])
    assert_equal "999ms", install.send(:format_elapsed, 999)
    assert_equal "1000ms", install.send(:format_elapsed, 1000)
  end

  def test_format_elapsed_uses_seconds_for_long_durations
    install = Scint::CLI::Install.new([])
    assert_equal "1.0s", install.send(:format_elapsed, 1001)
    assert_equal "2.35s", install.send(:format_elapsed, 2349)
  end

  def test_read_require_paths_uses_gemspec_paths
    with_tmpdir do |dir|
      spec_file = File.join(dir, "concurrent-ruby-1.3.6.gemspec")
      gemspec = Gem::Specification.new do |s|
        s.name = "concurrent-ruby"
        s.version = Gem::Version.new("1.3.6")
        s.summary = "test"
        s.authors = ["scint-test"]
        s.files = []
        s.require_paths = ["lib/concurrent-ruby"]
      end
      File.write(spec_file, gemspec.to_ruby)

      install = Scint::CLI::Install.new([])
      assert_equal ["lib/concurrent-ruby"], install.send(:read_require_paths, spec_file)
    end
  end

  def test_lockfile_to_resolved_converts_source_objects_to_uris
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "rack",
          version: "2.2.8",
          platform: "ruby",
          dependencies: [],
          source: source,
          checksum: nil,
        },
      ],
      dependencies: {},
      platforms: [],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    resolved = install.send(:lockfile_to_resolved, lockfile)
    assert_equal "https://rubygems.org/", resolved.first.source
  end

  def test_lockfile_to_resolved_preserves_git_source_objects
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Git.new(uri: "https://github.com/acme/demo.git", revision: "abc123")
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "demo",
          version: "1.0.0",
          platform: "ruby",
          dependencies: [],
          source: source,
          checksum: nil,
        },
      ],
      dependencies: {},
      platforms: [],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    resolved = install.send(:lockfile_to_resolved, lockfile)
    assert_equal Scint::Source::Git, resolved.first.source.class
    assert_equal "https://github.com/acme/demo.git", resolved.first.source.uri
    assert_equal "abc123", resolved.first.source.revision
  end

  def test_warn_missing_bundle_gitignore_entry_warns_when_missing
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write(".gitignore", "tmp/\nlog/\n")

        install = Scint::CLI::Install.new([])
        with_captured_stderr do |err|
          install.send(:warn_missing_bundle_gitignore_entry)
          assert_includes err.string, "does not ignore .bundle"
        end
      end
    end
  end

  def test_warn_missing_bundle_gitignore_entry_noop_when_bundle_present
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write(".gitignore", "tmp/\n.bundle/\n")

        install = Scint::CLI::Install.new([])
        with_captured_stderr do |err|
          install.send(:warn_missing_bundle_gitignore_entry)
          assert_equal "", err.string
        end
      end
    end
  end

  def test_parse_options_accepts_force_flag
    install = Scint::CLI::Install.new(["--force"])
    assert_equal true, install.instance_variable_get(:@force)
  end

  def test_adjust_meta_gems_adds_scint_once_and_removes_bundler
    install = Scint::CLI::Install.new([])
    resolved = [
      fake_spec(name: "rack", version: "2.2.8"),
      fake_spec(name: "bundler", version: "2.5.0"),
      fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)"),
    ]

    adjusted = install.send(:adjust_meta_gems, resolved)
    deduped = install.send(:dedupe_resolved_specs, adjusted)

    assert_equal 0, deduped.count { |s| s.name == "bundler" }
    assert_equal 1, deduped.count { |s| s.name == "scint" }
  end

  def test_force_purge_artifacts_removes_cache_and_local_bundle_entries
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new(["--force"])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "rack", version: "2.2.8")
      full = cache.full_name(spec)

      inbound = cache.inbound_path(spec)
      extracted = cache.extracted_path(spec)
      spec_cache = cache.spec_cache_path(spec)
      global_ext = cache.ext_path(spec)
      local_gem = File.join(ruby_dir, "gems", full)
      local_spec = File.join(ruby_dir, "specifications", "#{full}.gemspec")
      local_ext = File.join(ruby_dir, "extensions",
                            Scint::Platform.gem_arch, Scint::Platform.extension_api_version, full)
      bundle_bin = File.join(bundle_path, "bin")
      ruby_bin = File.join(ruby_dir, "bin")
      runtime_lock = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)

      FileUtils.mkdir_p(File.dirname(inbound))
      File.write(inbound, "gem-bytes")
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "x"), "x")
      FileUtils.mkdir_p(File.dirname(spec_cache))
      File.write(spec_cache, "meta")
      FileUtils.mkdir_p(global_ext)
      File.write(File.join(global_ext, "gem.build_complete"), "")
      FileUtils.mkdir_p(local_gem)
      File.write(File.join(local_gem, "rack.rb"), "")
      FileUtils.mkdir_p(File.dirname(local_spec))
      File.write(local_spec, "Gem::Specification.new")
      FileUtils.mkdir_p(local_ext)
      File.write(File.join(local_ext, "rack_ext.so"), "bin")
      FileUtils.mkdir_p(bundle_bin)
      File.write(File.join(bundle_bin, "rackup"), "")
      FileUtils.mkdir_p(ruby_bin)
      File.write(File.join(ruby_bin, "rackup"), "")
      FileUtils.mkdir_p(bundle_path)
      File.write(runtime_lock, "lock")

      install.send(:force_purge_artifacts, [spec], bundle_path, cache)

      refute File.exist?(inbound)
      refute Dir.exist?(extracted)
      refute File.exist?(spec_cache)
      refute Dir.exist?(global_ext)
      refute Dir.exist?(local_gem)
      refute File.exist?(local_spec)
      refute Dir.exist?(local_ext)
      refute Dir.exist?(bundle_bin)
      refute Dir.exist?(ruby_bin)
      refute File.exist?(runtime_lock)
    end
  end
end
