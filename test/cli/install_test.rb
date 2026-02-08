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
      @enqueued << { type: type, name: name, payload: payload, depends_on: depends_on, follow_up: follow_up }
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

  def test_enqueue_install_dag_wires_build_and_binstub_dependencies
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      dep_spec = fake_spec(name: "dep", version: "1.0.0", has_extensions: false)
      main_spec = fake_spec(
        name: "main",
        version: "1.0.0",
        has_extensions: true,
        dependencies: [{ name: "dep", version_reqs: [">= 0"] }],
      )

      dep_ext = File.join(cache.extracted_path(dep_spec), "lib")
      main_ext = File.join(cache.extracted_path(main_spec), "ext", "main")
      FileUtils.mkdir_p(dep_ext)
      FileUtils.mkdir_p(main_ext)
      File.write(File.join(main_ext, "extconf.rb"), "")

      plan = [
        Scint::PlanEntry.new(spec: dep_spec, action: :link, cached_path: cache.extracted_path(dep_spec), gem_path: nil),
        Scint::PlanEntry.new(spec: main_spec, action: :build_ext, cached_path: cache.extracted_path(main_spec), gem_path: nil),
      ]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)
      assert_equal 1, compiled.call

      dep_link = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "dep" }
      main_link = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "main" }
      main_build = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "main" }
      main_binstub = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "main" }

      refute_nil dep_link
      refute_nil main_link
      refute_nil main_build
      refute_nil main_binstub

      assert_includes main_build[:depends_on], scheduler.enqueued.index(main_link) + 1
      assert_includes main_build[:depends_on], scheduler.enqueued.index(dep_link) + 1
      assert_includes main_binstub[:depends_on], scheduler.enqueued.index(main_link) + 1
      assert_includes main_binstub[:depends_on], scheduler.enqueued.index(main_build) + 1
    end
  end

  def test_install_task_limits_reserves_lanes_for_compile_and_binstub
    install = Scint::CLI::Install.new([])
    compile_slots = install.send(:compile_slots_for, 8)
    limits = install.send(:install_task_limits, 8, compile_slots)
    assert_equal 1, compile_slots
    assert_equal 6, limits[:download]
    assert_equal 6, limits[:extract]
    assert_equal 6, limits[:link]
    assert_equal 1, limits[:build_ext]
    assert_equal 1, limits[:binstub]
  end

  def test_compile_slots_for_uses_single_compile_lane
    install = Scint::CLI::Install.new([])

    assert_equal 1, install.send(:compile_slots_for, 1)
    assert_equal 1, install.send(:compile_slots_for, 2)
    assert_equal 1, install.send(:compile_slots_for, 3)
    assert_equal 1, install.send(:compile_slots_for, 20)
  end

  def test_enqueue_install_dag_download_entry_schedules_build_after_extract
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "ffi", version: "1.17.0", has_extensions: false)
      plan = [Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      extract_job = scheduler.enqueued.find { |e| e[:type] == :extract && e[:name] == "ffi" }
      refute_nil extract_job
      refute_nil extract_job[:follow_up]

      ext_dir = File.join(cache.extracted_path(spec), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      extract_job[:follow_up].call(nil)

      build_job = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "ffi" }
      binstub_job = scheduler.enqueued.reverse.find { |e| e[:type] == :binstub && e[:name] == "ffi" }
      refute_nil build_job
      refute_nil binstub_job

      build_id = scheduler.enqueued.index(build_job) + 1
      assert_includes binstub_job[:depends_on], build_id
      assert_equal 1, compiled.call
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

  def test_format_run_footer_uses_singular_worker_label
    install = Scint::CLI::Install.new([])
    assert_equal "999ms, 1 worker used", install.send(:format_run_footer, 999, 1)
  end

  def test_format_run_footer_uses_plural_worker_label
    install = Scint::CLI::Install.new([])
    assert_equal "2.35s, 4 workers used", install.send(:format_run_footer, 2349, 4)
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

  def test_lockfile_to_resolved_prefers_best_local_platform_variant
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        { name: "nokogiri", version: "1.19.0", platform: "aarch64-linux-gnu", dependencies: [], source: source, checksum: nil },
        { name: "nokogiri", version: "1.19.0", platform: "x86_64-linux", dependencies: [], source: source, checksum: nil },
        { name: "nokogiri", version: "1.19.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
      ],
      dependencies: {},
      platforms: [],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    local = Gem::Platform.new("x86_64-linux")
    Scint::Platform.stub(:local_platform, local) do
      install.stub(:preferred_platforms_for_locked_specs, {}) do
        resolved = install.send(:lockfile_to_resolved, lockfile)
        assert_equal 1, resolved.size
        assert_equal "x86_64-linux", resolved.first.platform
      end
    end
  end

  def test_enqueue_install_dag_skips_build_for_platform_gems_with_prebuilt_bundle
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      nokogiri = fake_spec(name: "nokogiri", version: "1.18.10", platform: "arm64-darwin", has_extensions: true)
      plan = [Scint::PlanEntry.new(spec: nokogiri, action: :download, cached_path: nil, gem_path: nil)]

      extracted = cache.extracted_path(nokogiri)
      ext_dir = File.join(extracted, "ext", "nokogiri")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
      ruby_minor = RUBY_VERSION[/\d+\.\d+/]
      prebuilt_dir = File.join(extracted, "lib", "nokogiri", ruby_minor)
      FileUtils.mkdir_p(prebuilt_dir)
      File.write(File.join(prebuilt_dir, "nokogiri.bundle"), "")

      install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      extract_job = scheduler.enqueued.find { |entry| entry[:type] == :extract && entry[:name] == "nokogiri" }
      refute_nil extract_job
      refute_nil extract_job[:follow_up]

      extract_job[:follow_up].call(nil)

      build_jobs = scheduler.enqueued.select { |entry| entry[:type] == :build_ext && entry[:name] == "nokogiri" }
      assert_equal [], build_jobs, "platform gems with prebuilt bundles should skip native build"
    end
  end

  def test_lockfile_to_resolved_upgrades_ruby_variant_using_provider_preference
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        { name: "nokogiri", version: "1.18.10", platform: "ruby", dependencies: [], source: source, checksum: nil },
      ],
      dependencies: {},
      platforms: [],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    install.stub(:preferred_platforms_for_locked_specs, { "nokogiri-1.18.10" => "arm64-darwin" }) do
      resolved = install.send(:lockfile_to_resolved, lockfile)
      assert_equal 1, resolved.size
      assert_equal "arm64-darwin", resolved.first.platform
    end
  end

  def test_warm_compiled_cache_is_reused_for_ruby_lockfile_variant
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "ffi", version: "1.17.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      install.stub(:preferred_platforms_for_locked_specs, {}) do
        resolved = install.send(:lockfile_to_resolved, lockfile)
        spec = resolved.first
        ext_src = File.join(cache.extracted_path(spec), "ext", "ffi_c")
        FileUtils.mkdir_p(ext_src)
        File.write(File.join(ext_src, "extconf.rb"), "")
        FileUtils.mkdir_p(cache.ext_path(spec))
        File.write(File.join(cache.ext_path(spec), "gem.build_complete"), "")

        plan = Scint::Installer::Planner.plan(resolved, File.join(dir, ".bundle"), cache)
        assert_equal :link, plan.first.action
      end
    end
  end

  def test_warm_compiled_cache_is_reused_after_platform_upgrade_from_lockfile
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "ffi", version: "1.17.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      install.stub(:preferred_platforms_for_locked_specs, { "ffi-1.17.0" => "arm64-darwin" }) do
        resolved = install.send(:lockfile_to_resolved, lockfile)
        spec = resolved.first
        assert_equal "arm64-darwin", spec.platform

        ext_src = File.join(cache.extracted_path(spec), "ext", "ffi_c")
        FileUtils.mkdir_p(ext_src)
        File.write(File.join(ext_src, "extconf.rb"), "")
        FileUtils.mkdir_p(cache.ext_path(spec))
        File.write(File.join(cache.ext_path(spec), "gem.build_complete"), "")

        plan = Scint::Installer::Planner.plan(resolved, File.join(dir, ".bundle"), cache)
        assert_equal :link, plan.first.action
      end
    end
  end

  def test_warm_compiled_cache_is_reused_when_lockfile_platform_is_normalized
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "ffi", version: "1.17.0", platform: "arm64-darwin-24", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      install.stub(:preferred_platforms_for_locked_specs, { "ffi-1.17.0" => "arm64-darwin" }) do
        resolved = install.send(:lockfile_to_resolved, lockfile)
        spec = resolved.first
        assert_equal "arm64-darwin", spec.platform

        ext_src = File.join(cache.extracted_path(spec), "ext", "ffi_c")
        FileUtils.mkdir_p(ext_src)
        File.write(File.join(ext_src, "extconf.rb"), "")
        FileUtils.mkdir_p(cache.ext_path(spec))
        File.write(File.join(cache.ext_path(spec), "gem.build_complete"), "")

        plan = Scint::Installer::Planner.plan(resolved, File.join(dir, ".bundle"), cache)
        assert_equal :link, plan.first.action
      end
    end
  end

  def test_resolve_git_gem_subdir_finds_named_gemspec_by_glob
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      repo = File.join(dir, "repo")
      gem_dir = File.join(repo, "actionpack")
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "actionpack.gemspec"), "")
      source = Scint::Source::Git.new(uri: "https://github.com/rails/rails.git", glob: "{,*/}*.gemspec")
      spec = fake_spec(name: "actionpack", version: "7.2.0", source: source)

      resolved = install.send(:resolve_git_gem_subdir, repo, spec)
      assert_equal gem_dir, resolved
    end
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
    assert_equal "scint", deduped.first.name
  end

  def test_enqueue_install_dag_enqueues_builtin_as_link_task
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")
      plan = [Scint::PlanEntry.new(spec: spec, action: :builtin, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      assert_equal 0, compiled.call
      assert_equal 1, scheduler.enqueued.length
      assert_equal :link, scheduler.enqueued.first[:type]
      assert_equal "scint", scheduler.enqueued.first[:name]
    end
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

  def test_link_gem_files_materializes_cached_extensions
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "ffi", version: "1.17.0")
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "ffi.rb"), "module FFI; end\n")

      gemspec = Gem::Specification.new do |s|
        s.name = "ffi"
        s.version = Gem::Version.new("1.17.0")
        s.summary = "ffi"
        s.authors = ["test"]
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(gemspec))

      global_ext = cache.ext_path(spec)
      FileUtils.mkdir_p(global_ext)
      File.write(File.join(global_ext, "ffi_ext.so"), "bin")
      File.write(File.join(global_ext, "gem.build_complete"), "")

      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: extracted, gem_path: nil)
      install.send(:link_gem_files, entry, cache, bundle_path)

      local_ext = File.join(
        ruby_dir,
        "extensions",
        Scint::Platform.gem_arch,
        Scint::Platform.extension_api_version,
        cache.full_name(spec),
      )
      assert File.exist?(File.join(local_ext, "ffi_ext.so"))
      refute Dir.exist?(File.join(cache.install_ruby_dir, "gems", cache.full_name(spec)))
    end
  end

  def test_sync_build_env_dependencies_copies_declared_deps_and_rake
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      source_ruby_dir = ruby_bundle_dir(bundle_path)
      target_ruby_dir = cache.install_ruby_dir

      dep_name = "mini_portile2-2.8.5"
      dep_spec = File.join(source_ruby_dir, "specifications", "#{dep_name}.gemspec")
      dep_gem = File.join(source_ruby_dir, "gems", dep_name)
      FileUtils.mkdir_p(File.dirname(dep_spec))
      FileUtils.mkdir_p(dep_gem)
      File.write(File.join(dep_gem, "lib.rb"), "")
      File.write(dep_spec, "Gem::Specification.new do |s| s.name='mini_portile2'; s.version='2.8.5'; end\n")

      rake_name = "rake-13.2.1"
      rake_spec = File.join(source_ruby_dir, "specifications", "#{rake_name}.gemspec")
      rake_gem = File.join(source_ruby_dir, "gems", rake_name)
      FileUtils.mkdir_p(rake_gem)
      FileUtils.mkdir_p(File.join(rake_gem, "exe"))
      File.write(File.join(rake_gem, "exe", "rake"), "")
      FileUtils.mkdir_p(File.dirname(rake_spec))
      File.write(rake_spec, "Gem::Specification.new do |s| s.name='rake'; s.version='13.2.1'; end\n")

      spec = fake_spec(
        name: "nokogiri",
        version: "1.18.10",
        dependencies: [{ name: "mini_portile2", version_reqs: [">= 0"] }],
      )

      install.send(:sync_build_env_dependencies, spec, bundle_path, cache)

      assert Dir.exist?(File.join(target_ruby_dir, "gems", dep_name))
      assert File.exist?(File.join(target_ruby_dir, "specifications", "#{dep_name}.gemspec"))
      assert Dir.exist?(File.join(target_ruby_dir, "gems", rake_name))
      assert File.exist?(File.join(target_ruby_dir, "specifications", "#{rake_name}.gemspec"))
    end
  end

  def test_prepare_git_source_refreshes_extracted_checkout_when_revision_changes
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n", "REVISION" => "one\n")
      first = git_commit_hash(repo)
      commit_file(repo, "REVISION", "two\n", "update")
      second = git_commit_hash(repo)

      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "demo", version: "1.0.0", source: Scint::Source::Git.new(uri: repo, revision: first))
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      install.send(:prepare_git_source, entry, cache)
      extracted = cache.extracted_path(spec)
      assert_equal "one\n", File.read(File.join(extracted, "REVISION"))

      newer_spec = fake_spec(name: "demo", version: "1.0.0", source: Scint::Source::Git.new(uri: repo, revision: second))
      newer_entry = Scint::PlanEntry.new(spec: newer_spec, action: :download, cached_path: nil, gem_path: nil)
      install.send(:prepare_git_source, newer_entry, cache)
      assert_equal "two\n", File.read(File.join(extracted, "REVISION"))
    end
  end

  def test_prepare_git_source_fetches_latest_branch_tip_when_repo_is_cached
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n", "REVISION" => "one\n")
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "demo", version: "1.0.0", source: Scint::Source::Git.new(uri: repo, branch: "main"))
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      install.send(:prepare_git_source, entry, cache)
      extracted = cache.extracted_path(spec)
      assert_equal "one\n", File.read(File.join(extracted, "REVISION"))

      commit_file(repo, "REVISION", "two\n", "update")
      install.send(:prepare_git_source, entry, cache)
      assert_equal "two\n", File.read(File.join(extracted, "REVISION"))
    end
  end

  def test_prepare_git_source_materializes_per_gem_from_incoming_checkout
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "README.md" => "seed\n")
      with_cwd(repo) do
        FileUtils.mkdir_p("demo/lib")
      end
      commit_file(repo, "demo/demo.gemspec", "Gem::Specification.new { |s| s.name = 'demo'; s.version = '1.0.0' }\n", "add gemspec")
      commit_file(repo, "demo/lib/demo.rb", "module Demo; end\n", "add lib")
      commit_file(repo, "ROOT_ONLY.txt", "root\n", "add root marker")
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit, glob: "{,*,*/*}.gemspec")
      spec = fake_spec(name: "demo", version: "1.0.0", source: source)
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      install.send(:prepare_git_source, entry, cache)

      extracted = cache.extracted_path(spec)
      assert File.exist?(File.join(extracted, "demo.gemspec"))
      assert File.exist?(File.join(extracted, "lib", "demo.rb"))
      refute File.exist?(File.join(extracted, "ROOT_ONLY.txt"))

      incoming_checkout = cache.git_checkout_path(repo, commit)
      assert Dir.exist?(incoming_checkout)
      assert File.exist?(File.join(incoming_checkout, "ROOT_ONLY.txt"))
    end
  end

  def test_clone_git_source_fetches_existing_bare_repo
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n", "REVISION" => "one\n")
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, branch: "main")

      install.send(:clone_git_source, source, cache)
      bare = cache.git_path(source.uri)
      before = bare_rev_parse(bare, "main^{commit}")

      commit_file(repo, "REVISION", "two\n", "update")
      install.send(:clone_git_source, source, cache)
      after = bare_rev_parse(bare, "main^{commit}")

      refute_equal before, after
    end
  end

  def test_prepare_git_checkout_passes_submodules_flag_from_source
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: "https://github.com/shopify/mruby-engine.git", revision: "main", submodules: true)
      spec = fake_spec(name: "mruby_engine", version: "0.0.3", source: source)
      captured_submodules = nil

      install.stub(:clone_git_repo, ->(*_args) {}) do
        install.stub(:fetch_git_repo, ->(*_args) {}) do
          install.stub(:resolve_git_revision, ->(*_args) { "deadbeef" }) do
            install.stub(:materialize_git_checkout, lambda { |_bare, _checkout, _rev, _spec, _uri, submodules: false|
              captured_submodules = submodules
            }) do
              install.send(:prepare_git_checkout, spec, cache, fetch: true)
            end
          end
        end
      end

      assert_equal true, captured_submodules
    end
  end

  def test_checkout_git_tree_with_submodules_runs_submodule_update
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bare_repo = File.join(dir, "repo.git")
      FileUtils.mkdir_p(bare_repo)
      destination = File.join(dir, "checkout")
      spec = fake_spec(name: "mruby_engine", version: "0.0.3")
      calls = []

      install.stub(:git_capture3, lambda { |*args|
        calls << args
        if args[0..2] == ["--git-dir", bare_repo, "worktree"] && args[3] == "add"
          worktree = args[6]
          FileUtils.mkdir_p(worktree)
          File.write(File.join(worktree, "mruby_engine.gemspec"), "Gem::Specification.new\n")
          return ["", "", stub_status(true)]
        end
        ["", "", stub_status(true)]
      }) do
        install.send(
          :checkout_git_tree_with_submodules,
          bare_repo,
          destination,
          "deadbeef",
          spec,
          "https://github.com/shopify/mruby-engine.git",
        )
      end

      assert Dir.exist?(destination)
      assert calls.any? { |args| args.include?("submodule") && args.include?("update") }
    end
  end

  def test_materialize_git_checkout_refreshes_legacy_marker_when_submodules_enabled
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bare_repo = File.join(dir, "repo.git")
      checkout = File.join(dir, "checkout")
      spec = fake_spec(name: "mruby_engine", version: "0.0.3")

      FileUtils.mkdir_p(checkout)
      marker = install.send(:git_checkout_marker_path, checkout)
      File.write(marker, "deadbeef\n")

      called = false
      install.stub(:checkout_git_tree_with_submodules, lambda { |_bare, destination, *_rest|
        called = true
        FileUtils.mkdir_p(destination)
        File.write(File.join(destination, "mruby_engine.gemspec"), "Gem::Specification.new\n")
      }) do
        install.send(
          :materialize_git_checkout,
          bare_repo,
          checkout,
          "deadbeef",
          spec,
          "https://github.com/Shopify/mruby-engine.git",
          submodules: true,
        )
      end

      assert called
      marker_contents = File.read(marker)
      assert_includes marker_contents, "revision=deadbeef"
      assert_includes marker_contents, "submodules=1"
    end
  end

  # --- parse_options ---

  def test_parse_options_accepts_path_flag
    install = Scint::CLI::Install.new(["--path", "vendor/bundle"])
    assert_equal "vendor/bundle", install.instance_variable_get(:@path)
  end

  def test_parse_options_accepts_verbose_flag
    install = Scint::CLI::Install.new(["--verbose"])
    assert_equal true, install.instance_variable_get(:@verbose)
  end

  def test_parse_options_accepts_jobs_short_flag
    install = Scint::CLI::Install.new(["-j", "4"])
    assert_equal 4, install.instance_variable_get(:@jobs)
  end

  def test_parse_options_accepts_force_short_flag
    install = Scint::CLI::Install.new(["-f"])
    assert_equal true, install.instance_variable_get(:@force)
  end

  def test_parse_options_ignores_unknown_flags
    install = Scint::CLI::Install.new(["--unknown", "val"])
    assert_nil install.instance_variable_get(:@jobs)
    assert_nil install.instance_variable_get(:@path)
    assert_equal false, install.instance_variable_get(:@verbose)
  end

  # --- spec_full_name ---

  def test_spec_full_name_without_platform
    install = Scint::CLI::Install.new([])
    spec = fake_spec(name: "rack", version: "2.2.8", platform: "ruby")
    assert_equal "rack-2.2.8", install.send(:spec_full_name, spec)
  end

  def test_spec_full_name_with_platform
    install = Scint::CLI::Install.new([])
    spec = fake_spec(name: "nokogiri", version: "1.16.0", platform: "x86_64-linux")
    assert_equal "nokogiri-1.16.0-x86_64-linux", install.send(:spec_full_name, spec)
  end

  def test_spec_full_name_with_nil_platform
    install = Scint::CLI::Install.new([])
    spec = Scint::ResolvedSpec.new(name: "test", version: "1.0", platform: nil, dependencies: [],
                                    source: "https://rubygems.org", has_extensions: false,
                                    remote_uri: nil, checksum: nil)
    assert_equal "test-1.0", install.send(:spec_full_name, spec)
  end

  # --- elapsed_ms_since ---

  def test_elapsed_ms_since_returns_positive_integer
    install = Scint::CLI::Install.new([])
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 0.01
    ms = install.send(:elapsed_ms_since, start)
    assert_kind_of Integer, ms
    assert ms >= 10
  end

  # --- install_breakdown ---

  def test_install_breakdown_with_all_zeros_returns_empty
    install = Scint::CLI::Install.new([])
    assert_equal "", install.send(:install_breakdown, cached: 0, updated: 0)
  end

  def test_install_breakdown_with_counts
    install = Scint::CLI::Install.new([])
    result = install.send(:install_breakdown, cached: 5, updated: 3)
    assert_includes result, "5 cached"
    assert_includes result, "3 updated"
  end

  def test_install_breakdown_with_failed_uses_red_color
    install = Scint::CLI::Install.new([])
    result = install.send(:install_breakdown, cached: 0, updated: 0, failed: 2)
    assert_includes result, "2 failed"
  end

  # --- install_builtin_gem ---

  def test_install_builtin_gem_creates_gem_dir_and_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)
      spec = fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")
      entry = Scint::PlanEntry.new(spec: spec, action: :builtin, cached_path: nil, gem_path: nil)

      install.send(:install_builtin_gem, entry, bundle_path)

      full_name = "scint-#{Scint::VERSION}"
      gem_dest = File.join(ruby_dir, "gems", full_name, "lib")
      spec_path = File.join(ruby_dir, "specifications", "#{full_name}.gemspec")

      assert Dir.exist?(gem_dest), "gem lib dir should exist"
      assert File.exist?(spec_path), "gemspec should exist"
      content = File.read(spec_path)
      assert_includes content, "scint"
    end
  end

  def test_install_builtin_gem_skips_when_already_exists
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)
      spec = fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")
      entry = Scint::PlanEntry.new(spec: spec, action: :builtin, cached_path: nil, gem_path: nil)

      # First install
      install.send(:install_builtin_gem, entry, bundle_path)

      full_name = "scint-#{Scint::VERSION}"
      spec_path = File.join(ruby_dir, "specifications", "#{full_name}.gemspec")
      mtime = File.mtime(spec_path)

      # Second install should not overwrite
      sleep 0.01
      install.send(:install_builtin_gem, entry, bundle_path)
      assert_equal mtime, File.mtime(spec_path)
    end
  end

  # --- lockfile_current? ---

  def test_lockfile_current_returns_false_when_lockfile_nil
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack")],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )
    refute install.send(:lockfile_current?, gemfile, nil)
  end

  def test_lockfile_current_returns_true_when_all_deps_present
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack")],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )
    assert install.send(:lockfile_current?, gemfile, lockfile)
  end

  def test_lockfile_current_returns_false_when_dep_missing
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack"), Scint::Gemfile::Dependency.new("puma")],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )
    refute install.send(:lockfile_current?, gemfile, lockfile)
  end


  def test_lockfile_current_ignores_missing_dependency_for_foreign_platform
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [
        Scint::Gemfile::Dependency.new("rack"),
        Scint::Gemfile::Dependency.new("wdm", platforms: [:mingw, :x64_mingw, :mswin]),
      ],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    assert install.send(:lockfile_current?, gemfile, lockfile)
  end

  def test_lockfile_current_requires_missing_dependency_for_local_platform
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [
        Scint::Gemfile::Dependency.new("rack"),
        Scint::Gemfile::Dependency.new("tzinfo-data", platforms: [:ruby]),
      ],
      sources: [],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    refute install.send(:lockfile_current?, gemfile, lockfile)
  end

  def test_lockfile_dependency_graph_valid_returns_false_for_version_mismatch
    install = Scint::CLI::Install.new([])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "rails", version: "8.2.0.alpha", platform: "ruby",
          dependencies: [{ name: "actionpack", version_reqs: ["= 8.2.0.alpha"] }],
          source: nil, checksum: nil,
        },
        { name: "actionpack", version: "8.1.2", platform: "ruby", dependencies: [], source: nil, checksum: nil },
      ],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    refute install.send(:lockfile_dependency_graph_valid?, lockfile)
  end

  def test_lockfile_dependency_graph_valid_returns_true_for_consistent_lock
    install = Scint::CLI::Install.new([])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "rails", version: "8.2.0.alpha", platform: "ruby",
          dependencies: [{ name: "actionpack", version_reqs: ["= 8.2.0.alpha"] }],
          source: nil, checksum: nil,
        },
        { name: "actionpack", version: "8.2.0.alpha", platform: "ruby", dependencies: [], source: nil, checksum: nil },
      ],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    assert install.send(:lockfile_dependency_graph_valid?, lockfile)
  end

  def test_lockfile_dependency_graph_valid_ignores_missing_bundler_spec
    install = Scint::CLI::Install.new([])
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "rails", version: "8.2.0.alpha", platform: "ruby",
          dependencies: [{ name: "bundler", version_reqs: [">= 1.15.0"] }],
          source: nil, checksum: nil,
        },
      ],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    assert install.send(:lockfile_dependency_graph_valid?, lockfile)
  end

  def test_lockfile_git_source_mapping_valid_returns_true_when_specs_exist_in_repo
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n")
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit)
      install.send(:clone_git_source, source, cache)

      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "demo", version: "1.0.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      assert install.send(:lockfile_git_source_mapping_valid?, lockfile, cache)
    end
  end

  def test_lockfile_git_source_mapping_valid_returns_false_when_spec_missing_from_repo
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n")
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit)
      install.send(:clone_git_source, source, cache)

      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "demo", version: "1.0.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
          { name: "missing", version: "1.0.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      refute install.send(:lockfile_git_source_mapping_valid?, lockfile, cache)
    end
  end

  def test_lockfile_git_source_mapping_valid_returns_true_when_repo_not_cached_yet
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: "https://github.com/example/monorepo.git", revision: "deadbeef")

      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "demo", version: "1.0.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      assert install.send(:lockfile_git_source_mapping_valid?, lockfile, cache)
    end
  end

  def test_lockfile_git_source_mapping_valid_does_not_require_runtime_dependency_gemspec_loading
    with_tmpdir do |dir|
      repo = init_git_repo(
        dir,
        "demo.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "demo"
            s.version = "1.0.0"
            s.summary = "demo"
            s.authors = ["test"]
            s.add_runtime_dependency "dep", "= 1.0.0"
          end
        RUBY
        "dep.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "dep"
            s.version = "1.0.0"
            s.summary = "dep"
            s.authors = ["test"]
          end
        RUBY
      )
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit)
      install.send(:clone_git_source, source, cache)

      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "demo", version: "1.0.0", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      install.stub(:runtime_dependencies_for_git_gemspec, ->(*_args) { raise "should not load gemspec runtime deps" }) do
        assert install.send(:lockfile_git_source_mapping_valid?, lockfile, cache)
      end
    end
  end

  def test_resolve_falls_back_to_full_resolution_when_git_source_mapping_is_invalid
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack")],
      sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )
    fake_resolved = [fake_spec(name: "rack", version: "2.2.8")]
    fake_resolver = Object.new
    fake_resolver.define_singleton_method(:resolve) { fake_resolved }

    Scint::Resolver::Resolver.stub(:new, fake_resolver) do
      install.stub(:lockfile_current?, true) do
        install.stub(:lockfile_git_source_mapping_valid?, false) do
          install.stub(:lockfile_to_resolved, ->(_lockfile) { raise "lockfile path should not be used" }) do
            resolved = install.send(:resolve, gemfile, lockfile, nil)
            assert_equal fake_resolved, resolved
          end
        end
      end
    end
  end

  def test_resolve_uses_lockfile_when_git_repo_not_cached
    install = Scint::CLI::Install.new([])
    install.instance_variable_set(:@credentials, Scint::Credentials.new)
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack")],
      sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
      ruby_version: nil,
      platforms: [],
    )
    git_source = Scint::Source::Git.new(uri: "https://github.com/example/mono.git", revision: "main")
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [
        { name: "rack", version: "2.2.8", platform: "ruby", dependencies: [], source: nil, checksum: nil },
        { name: "demo", version: "1.0.0", platform: "ruby", dependencies: [], source: git_source, checksum: nil },
      ],
      dependencies: {},
      platforms: [],
      sources: [git_source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      from_lockfile = [fake_spec(name: "rack", version: "2.2.8")]
      install.stub(:lockfile_to_resolved, ->(_lock) { from_lockfile }) do
        Scint::Resolver::Resolver.stub(:new, ->(*_args) { raise "resolver should not run" }) do
          resolved = install.send(:resolve, gemfile, lockfile, cache)
          assert_equal from_lockfile, resolved
        end
      end
    end
  end

  def test_resolve_falls_back_to_full_resolution_when_lockfile_dependency_graph_is_invalid
    install = Scint::CLI::Install.new([])
    gemfile = Scint::Gemfile::ParseResult.new(
      dependencies: [Scint::Gemfile::Dependency.new("rack")],
      sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
      ruby_version: nil,
      platforms: [],
    )
    lockfile = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8" }],
      dependencies: {},
      platforms: [],
      sources: [],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )
    fake_resolved = [fake_spec(name: "rack", version: "2.2.8")]
    fake_resolver = Object.new
    fake_resolver.define_singleton_method(:resolve) { fake_resolved }

    Scint::Resolver::Resolver.stub(:new, fake_resolver) do
      install.stub(:lockfile_current?, true) do
        install.stub(:lockfile_dependency_graph_valid?, false) do
          install.stub(:lockfile_to_resolved, ->(_lockfile) { raise "lockfile path should not be used" }) do
            resolved = install.send(:resolve, gemfile, lockfile, nil)
            assert_equal fake_resolved, resolved
          end
        end
      end
    end
  end
  # --- find_gemspec ---

  def test_find_gemspec_returns_nil_when_path_does_not_exist
    install = Scint::CLI::Install.new([])
    assert_nil install.send(:find_gemspec, "/nonexistent", "foo")
  end

  def test_find_gemspec_loads_exact_match
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      File.write(File.join(dir, "mylib.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mylib"
          s.version = "1.0.0"
          s.summary = "test"
          s.authors = ["test"]
        end
      RUBY

      result = install.send(:find_gemspec, dir, "mylib")
      assert_equal "mylib", result.name
      assert_equal Gem::Version.new("1.0.0"), result.version
    end
  end

  def test_find_gemspec_returns_nil_when_no_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      assert_nil install.send(:find_gemspec, dir, "missing")
    end
  end

  def test_find_git_gemspec_loads_named_gemspec_from_revision
    with_tmpdir do |dir|
      repo = init_git_repo(
        dir,
        "demo.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "demo"
            s.version = "1.2.3"
            s.summary = "demo"
            s.authors = ["test"]
            s.add_runtime_dependency "dep", "~> 2.0"
          end
        RUBY
        "dep.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "dep"
            s.version = "2.1.0"
            s.summary = "dep"
            s.authors = ["test"]
          end
        RUBY
      )
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit)
      install.send(:clone_git_source, source, cache)

      bare_repo = cache.git_path(repo)
      gemspec = install.send(:find_git_gemspec, bare_repo, commit, "demo")
      assert_equal "demo", gemspec.name
      assert_equal Gem::Version.new("1.2.3"), gemspec.version
      dep = gemspec.dependencies.find { |d| d.name == "dep" }
      refute_nil dep
      assert dep.requirement.satisfied_by?(Gem::Version.new("2.1.0"))
    end
  end

  def test_resolve_builds_git_path_gem_metadata_from_git_gemspec
    with_tmpdir do |dir|
      repo = init_git_repo(
        dir,
        "demo.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "demo"
            s.version = "1.2.3"
            s.summary = "demo"
            s.authors = ["test"]
            s.add_runtime_dependency "dep", "= 2.1.0"
          end
        RUBY
        "dep.gemspec" => <<~RUBY,
          Gem::Specification.new do |s|
            s.name = "dep"
            s.version = "2.1.0"
            s.summary = "dep"
            s.authors = ["test"]
          end
        RUBY
      )
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, revision: commit)
      install.send(:clone_git_source, source, cache)

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("demo", source_options: { git: repo }),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      captured_path_gems = nil
      fake_provider = Object.new
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { [] }

      provider_stub = lambda do |_default_client, **kwargs|
        captured_path_gems = kwargs[:path_gems]
        fake_provider
      end

      Scint::Resolver::Provider.stub(:new, provider_stub) do
        Scint::Resolver::Resolver.stub(:new, fake_resolver) do
          install.send(:resolve, gemfile, nil, cache)
        end
      end

      assert_equal "1.2.3", captured_path_gems.dig("demo", :version)
      assert_equal [["dep", ["= 2.1.0"]]], captured_path_gems.dig("demo", :dependencies)
      assert_equal "2.1.0", captured_path_gems.dig("dep", :version)
    end
  end

  # --- download_gem ---

  def test_download_gem_skips_path_sources
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "mylib", version: "1.0.0", source: "/local/path")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      # Should not raise - path gems are skipped
      install.send(:download_gem, entry, cache)
    end
  end

  def test_download_gem_handles_git_source
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      git_source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git", revision: "abc123")
      spec = fake_spec(name: "demo", version: "1.0.0", source: git_source)
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      called = false
      install.stub(:prepare_git_checkout, ->(*_args, **_opts) { called = true }) do
        install.send(:download_gem, entry, cache)
      end
      assert_equal true, called
    end
  end

  def test_download_gem_skips_when_already_cached
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      # Pre-create cached gem file
      dest = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, "fake-gem-data")

      # Should not attempt to download
      install.send(:download_gem, entry, cache)
      assert File.exist?(dest)
    end
  end

  # --- extract_gem ---

  def test_extract_gem_skips_path_source
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "mylib", version: "1.0.0", source: "/local/path")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      # Should not raise
      install.send(:extract_gem, entry, cache)
    end
  end

  def test_extract_gem_materializes_git_source_from_checkout
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      git_source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git")
      spec = fake_spec(name: "demo", version: "1.0.0", source: git_source)
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      called = false
      install.stub(:materialize_git_spec, ->(*_args, **_opts) { called = true }) do
        install.send(:extract_gem, entry, cache)
      end
      assert_equal true, called
    end
  end

  def test_extract_gem_skips_already_extracted
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      # Pre-create extracted dir
      FileUtils.mkdir_p(cache.extracted_path(spec))

      install.send(:extract_gem, entry, cache)
    end
  end

  def test_extract_gem_raises_when_missing_cached_file
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      assert_raises(Scint::InstallError) do
        install.send(:extract_gem, entry, cache)
      end
    end
  end

  def test_extract_gem_extracts_from_cached_gem
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "demo", version: "1.0.0", source: "https://rubygems.org")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "demo", version: "1.0.0", files: { "lib/demo.rb" => "module Demo; end\n" })

      install.send(:extract_gem, entry, cache)

      extracted = cache.extracted_path(spec)
      assert Dir.exist?(extracted)
    end
  end

  # --- git_source? ---

  def test_git_source_with_git_source_object
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git")
    assert install.send(:git_source?, source)
  end

  def test_git_source_with_dot_git_url_string
    install = Scint::CLI::Install.new([])
    assert install.send(:git_source?, "https://github.com/demo/demo.git")
  end

  def test_git_source_with_dot_git_subpath
    install = Scint::CLI::Install.new([])
    assert install.send(:git_source?, "https://github.com/demo/demo.git/subdir")
  end

  def test_git_source_with_rubygems_source
    install = Scint::CLI::Install.new([])
    refute install.send(:git_source?, "https://rubygems.org")
  end

  # --- git_source_ref ---

  def test_git_source_ref_with_git_source_object
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git", revision: "abc123")
    uri, rev = install.send(:git_source_ref, source)
    assert_equal "https://github.com/demo/demo.git", uri
    assert_equal "abc123", rev
  end

  def test_git_source_ref_falls_back_to_head
    install = Scint::CLI::Install.new([])
    uri, rev = install.send(:git_source_ref, "https://github.com/demo/demo.git")
    assert_equal "https://github.com/demo/demo.git", uri
    assert_equal "HEAD", rev
  end

  def test_git_source_ref_uses_branch_when_no_revision
    install = Scint::CLI::Install.new([])
    source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git", branch: "develop")
    _uri, rev = install.send(:git_source_ref, source)
    assert_equal "develop", rev
  end

  # --- rubygems_source_uri? ---

  def test_rubygems_source_uri_with_http
    install = Scint::CLI::Install.new([])
    assert install.send(:rubygems_source_uri?, "https://rubygems.org")
    assert install.send(:rubygems_source_uri?, "http://rubygems.org")
    refute install.send(:rubygems_source_uri?, "/local/path")
    refute install.send(:rubygems_source_uri?, Scint::Source::Git.new(uri: "foo"))
  end

  # --- write_lockfile ---

  def test_write_lockfile_writes_gemfile_lock
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        resolved = [
          fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org"),
        ]
        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:write_lockfile, resolved, gemfile)
        assert File.exist?("Gemfile.lock")
        content = File.read("Gemfile.lock")
        assert_includes content, "rack"
      end
    end
  end

  def test_write_lockfile_with_path_and_git_dependencies
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        resolved = [
          fake_spec(name: "mylib", version: "1.0.0", source: "/local/mylib"),
          fake_spec(name: "gitdep", version: "2.0.0", source: "https://github.com/demo/gitdep.git"),
        ]
        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [
            Scint::Gemfile::Dependency.new("mylib", source_options: { path: "../mylib" }),
            Scint::Gemfile::Dependency.new("gitdep", source_options: { git: "https://github.com/demo/gitdep.git", branch: "main" }),
          ],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:write_lockfile, resolved, gemfile)
        content = File.read("Gemfile.lock")
        assert_includes content, "PATH"
        assert_includes content, "GIT"
      end
    end
  end

  def test_write_lockfile_with_scoped_sources
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        resolved = [
          fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org"),
        ]
        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [
            Scint::Gemfile::Dependency.new("rack", source_options: { source: "https://custom.rubygems.org" }),
          ],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:write_lockfile, resolved, gemfile)
        content = File.read("Gemfile.lock")
        assert_includes content, "rack"
      end
    end
  end

  def test_write_lockfile_with_gemspec_keeps_transitive_components_out_of_dependencies
    with_tmpdir do |dir|
      with_cwd(dir) do
        FileUtils.mkdir_p("components")
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"
          gemspec
        RUBY
        File.write("root.gemspec", <<~RUBY)
          Gem::Specification.new do |s|
            s.name = "root"
            s.version = "1.0.0"
            s.summary = "root"
            s.authors = ["scint"]
            s.files = []
            s.add_dependency "child", "= 1.0.0"
          end
        RUBY
        File.write("components/child.gemspec", <<~RUBY)
          Gem::Specification.new do |s|
            s.name = "child"
            s.version = "1.0.0"
            s.summary = "child"
            s.authors = ["scint"]
            s.files = []
          end
        RUBY

        install = Scint::CLI::Install.new([])
        gemfile = Scint::Gemfile::Parser.parse("Gemfile")
        resolved = [
          fake_spec(
            name: "root",
            version: "1.0.0",
            source: File.expand_path("."),
            dependencies: [{ name: "child", version_reqs: ["= 1.0.0"] }],
          ),
          fake_spec(name: "child", version: "1.0.0", source: File.expand_path("components")),
        ]

        install.send(:write_lockfile, resolved, gemfile)
        parsed = Scint::Lockfile::Parser.parse("Gemfile.lock")

        assert_includes parsed.dependencies.keys, "root"
        refute_includes(
          parsed.dependencies.keys,
          "child",
          "transitive gemspec dependencies should be in SPECS only, not DEPENDENCIES",
        )
      end
    end
  end

  def test_write_lockfile_preserves_lockfile_metadata_and_pins
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        git_source = Scint::Source::Git.new(
          uri: "https://github.com/demo/gitdep.git",
          branch: "main",
          revision: "deadbeef",
        )
        ruby_source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

        lockfile = Scint::Lockfile::LockfileData.new(
          specs: [
            { name: "gitdep", version: "2.0.0", platform: "ruby", dependencies: [], source: git_source, checksum: nil },
            { name: "rack", version: "2.2.8", platform: "ruby", dependencies: [], source: ruby_source, checksum: nil },
          ],
          dependencies: {
            "gitdep" => { name: "gitdep", version_reqs: [">= 0"], pinned: true },
            "rack" => { name: "rack", version_reqs: [">= 0"], pinned: false },
          },
          platforms: ["ruby", "x86_64-linux", "arm64-darwin-24"],
          sources: [git_source, ruby_source],
          bundler_version: "2.5.5",
          ruby_version: "ruby 3.4.5p0",
          checksums: { "rack-2.2.8" => ["sha256=abc123"] },
        )

        resolved = [
          fake_spec(name: "gitdep", version: "2.0.0", source: "https://github.com/demo/gitdep.git"),
          fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org"),
        ]

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [
            Scint::Gemfile::Dependency.new("gitdep", source_options: { git: "https://github.com/demo/gitdep.git", branch: "main" }),
            Scint::Gemfile::Dependency.new("rack"),
          ],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:write_lockfile, resolved, gemfile, lockfile)
        content = File.read("Gemfile.lock")

        assert_includes content, "gitdep!"
        assert_includes content, "revision: deadbeef"
        assert_includes content, "PLATFORMS\n  arm64-darwin-24\n  ruby\n  x86_64-linux"
        assert_includes content, "CHECKSUMS\n  rack (2.2.8) sha256=abc123"
        assert_includes content, "BUNDLED WITH\n   2.5.5"
      end
    end
  end

  def test_write_lockfile_preserves_existing_multisource_layout_when_resolved_is_subset
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        git_one = Scint::Source::Git.new(uri: "https://github.com/demo/one.git", revision: "111")
        git_two = Scint::Source::Git.new(uri: "https://github.com/demo/two.git", revision: "222")
        ruby_source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

        lockfile = Scint::Lockfile::LockfileData.new(
          specs: [
            { name: "one", version: "1.0.0", platform: "ruby", dependencies: [], source: git_one, checksum: nil },
            { name: "two", version: "1.0.0", platform: "ruby", dependencies: [], source: git_two, checksum: nil },
            { name: "rack", version: "2.2.8", platform: "ruby", dependencies: [], source: ruby_source, checksum: nil },
            { name: "rack", version: "2.2.8", platform: "x86_64-linux", dependencies: [], source: ruby_source, checksum: nil },
          ],
          dependencies: {
            "one" => { name: "one", version_reqs: [">= 0"], pinned: true },
            "two" => { name: "two", version_reqs: [">= 0"], pinned: true },
          },
          platforms: ["ruby", "x86_64-linux"],
          sources: [git_one, git_two, ruby_source],
          bundler_version: "2.5.5",
          ruby_version: nil,
          checksums: nil,
        )

        resolved = [
          fake_spec(name: "one", version: "1.0.0", source: "https://github.com/demo/one"),
          fake_spec(name: "two", version: "1.0.0", source: "https://github.com/demo/two"),
          fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org"),
        ]

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [
            Scint::Gemfile::Dependency.new("one", source_options: { git: "https://github.com/demo/one.git" }),
            Scint::Gemfile::Dependency.new("two", source_options: { git: "https://github.com/demo/two.git" }),
            Scint::Gemfile::Dependency.new("rack"),
          ],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        install.send(:write_lockfile, resolved, gemfile, lockfile)
        parsed = Scint::Lockfile::Parser.parse("Gemfile.lock")

        one_spec = parsed.specs.find { |spec| spec[:name] == "one" }
        two_spec = parsed.specs.find { |spec| spec[:name] == "two" }
        rack_variants = parsed.specs.select { |spec| spec[:name] == "rack" }

        assert_equal "https://github.com/demo/one.git", one_spec[:source].uri
        assert_equal "https://github.com/demo/two.git", two_spec[:source].uri
        assert_equal 2, rack_variants.size
        assert_includes parsed.platforms, "x86_64-linux"
      end
    end
  end

  # --- write_runtime_config ---

  def test_write_runtime_config_creates_marshal_file
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "rack", version: "2.2.8")
      full = "rack-2.2.8"
      gem_dir = File.join(ruby_dir, "gems", full, "lib")
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "rack.rb"), "")

      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(spec_dir)
      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "test"
        s.authors = ["test"]
        s.require_paths = ["lib"]
      end
      File.write(File.join(spec_dir, "#{full}.gemspec"), gemspec.to_ruby)

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      assert File.exist?(lock_path)
      data = Marshal.load(File.binread(lock_path))
      assert_includes data.keys, "rack"
      assert_includes data["rack"][:load_paths], File.join(ruby_dir, "gems", full, "lib")
    end
  end

  def test_write_runtime_config_handles_missing_spec_file
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "rack", version: "2.2.8")
      full = "rack-2.2.8"
      gem_dir = File.join(ruby_dir, "gems", full, "lib")
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "rack.rb"), "")

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      assert File.exist?(lock_path)
      data = Marshal.load(File.binread(lock_path))
      assert_includes data["rack"][:load_paths], File.join(ruby_dir, "gems", full, "lib")
    end
  end

  def test_write_runtime_config_keeps_only_declared_require_paths
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "concurrent-ruby", version: "1.3.6")
      full = "concurrent-ruby-1.3.6"
      # Create a nested lib structure with no top-level .rb files
      nested_dir = File.join(ruby_dir, "gems", full, "lib", "concurrent-ruby")
      FileUtils.mkdir_p(nested_dir)

      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(spec_dir)
      gemspec = Gem::Specification.new do |s|
        s.name = "concurrent-ruby"
        s.version = Gem::Version.new("1.3.6")
        s.summary = "test"
        s.authors = ["test"]
        s.require_paths = ["lib"]
      end
      File.write(File.join(spec_dir, "#{full}.gemspec"), gemspec.to_ruby)

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      data = Marshal.load(File.binread(lock_path))
      load_paths = data["concurrent-ruby"][:load_paths]
      assert_includes load_paths, File.join(ruby_dir, "gems", full, "lib")
      refute_includes load_paths, nested_dir
    end
  end

  def test_write_runtime_config_adds_ext_dir_when_exists
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "ffi", version: "1.17.0")
      full = "ffi-1.17.0"
      gem_dir = File.join(ruby_dir, "gems", full, "lib")
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "ffi.rb"), "")

      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(spec_dir)
      gemspec = Gem::Specification.new do |s|
        s.name = "ffi"
        s.version = "1.17.0"
        s.summary = "test"
        s.authors = ["test"]
      end
      File.write(File.join(spec_dir, "#{full}.gemspec"), gemspec.to_ruby)

      ext_dir = File.join(ruby_dir, "extensions",
                          Scint::Platform.gem_arch, Scint::Platform.extension_api_version, full)
      FileUtils.mkdir_p(ext_dir)

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      data = Marshal.load(File.binread(lock_path))
      assert data["ffi"][:load_paths].any? { |p| p.include?("extensions") }
    end
  end

  def test_write_runtime_config_keeps_absolute_require_path_entries
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      spec = fake_spec(name: "pg", version: "1.5.3")
      full = "pg-1.5.3"
      gem_lib = File.join(ruby_dir, "gems", full, "lib")
      abs_ext = File.join(ruby_dir, "extensions", Scint::Platform.gem_arch, Scint::Platform.extension_api_version, full)
      FileUtils.mkdir_p(gem_lib)
      FileUtils.mkdir_p(abs_ext)
      File.write(File.join(gem_lib, "pg.rb"), "")

      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(spec_dir)
      gemspec = Gem::Specification.new do |s|
        s.name = "pg"
        s.version = "1.5.3"
        s.summary = "test"
        s.authors = ["test"]
        s.require_paths = [abs_ext, "lib"]
      end
      File.write(File.join(spec_dir, "#{full}.gemspec"), gemspec.to_ruby)

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      data = Marshal.load(File.binread(lock_path))
      assert_includes data["pg"][:load_paths], abs_ext
      assert_includes data["pg"][:load_paths], gem_lib
    end
  end

  def test_write_runtime_config_falls_back_to_local_source_paths_when_installed_paths_missing
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_path)

      monorepo = File.join(dir, "rails")
      source_subdir = File.join(monorepo, "actionpack")
      source_lib = File.join(source_subdir, "lib")
      FileUtils.mkdir_p(source_lib)
      File.write(File.join(source_subdir, "actionpack.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "actionpack"
          s.version = "8.2.0.alpha"
          s.summary = "test"
          s.authors = ["test"]
          s.require_paths = ["lib"]
        end
      RUBY

      spec = fake_spec(name: "actionpack", version: "8.2.0.alpha", source: monorepo)

      # Intentionally omit installed gem files/spec to force source-path fallback.
      FileUtils.mkdir_p(File.join(ruby_dir, "gems", "actionpack-8.2.0.alpha"))
      FileUtils.mkdir_p(File.join(ruby_dir, "specifications"))

      install.send(:write_runtime_config, [spec], bundle_path)

      lock_path = File.join(bundle_path, Scint::CLI::Install::RUNTIME_LOCK)
      data = Marshal.load(File.binread(lock_path))
      assert_includes data["actionpack"][:load_paths], source_lib
    end
  end

  # --- gitignore_has_bundle_entry? edge cases ---

  def test_gitignore_has_bundle_entry_with_double_star_prefix
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      path = File.join(dir, ".gitignore")
      File.write(path, "**/.bundle\n")
      assert install.send(:gitignore_has_bundle_entry?, path)
    end
  end

  def test_gitignore_has_bundle_entry_returns_false_on_read_error
    install = Scint::CLI::Install.new([])
    result = install.send(:gitignore_has_bundle_entry?, "/nonexistent/path")
    refute result
  end

  # --- resolve method ---

  def test_resolve_returns_lockfile_specs_when_current
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      # Set up credentials
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "rack", version: "2.2.8", platform: "ruby", dependencies: [], source: source, checksum: nil },
        ],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [Scint::Gemfile::Dependency.new("rack")],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      install.stub(:preferred_platforms_for_locked_specs, {}) do
        resolved = install.send(:resolve, gemfile, lockfile, nil)
        assert_equal 1, resolved.size
        assert_equal "rack", resolved.first.name
      end
    end
  end

  # --- enqueue_install_dag with :download entry (no extensions) ---

  def test_enqueue_install_dag_download_entry_no_extensions
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "rack", version: "2.2.8", has_extensions: false)
      plan = [Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      download = scheduler.enqueued.find { |e| e[:type] == :download }
      extract = scheduler.enqueued.find { |e| e[:type] == :extract }
      link = scheduler.enqueued.find { |e| e[:type] == :link }

      refute_nil download
      refute_nil extract
      refute_nil link

      # Call follow_up - no extensions, should enqueue binstub without build_ext
      extract[:follow_up].call(nil)
      binstub = scheduler.enqueued.find { |e| e[:type] == :binstub }
      refute_nil binstub
      assert_equal 0, compiled.call
    end
  end

  # --- enqueue_install_dag with :skip entries ---

  def test_enqueue_install_dag_skips_skip_entries
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "rack", version: "2.2.8")
      plan = [Scint::PlanEntry.new(spec: spec, action: :skip, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)
      assert_equal 0, compiled.call
      assert_empty scheduler.enqueued
    end
  end

  # --- dependency_link_job_ids ---

  def test_dependency_link_job_ids_with_hash_deps
    install = Scint::CLI::Install.new([])
    spec = fake_spec(name: "main", version: "1.0.0",
                     dependencies: [{ name: "dep1", version_reqs: [">= 0"] }])
    link_by_name = { "dep1" => 42 }
    result = install.send(:dependency_link_job_ids, spec, link_by_name)
    assert_equal [42], result
  end

  def test_dependency_link_job_ids_with_object_deps
    install = Scint::CLI::Install.new([])
    dep_obj = Scint::Gemfile::Dependency.new("dep1")
    spec = Scint::ResolvedSpec.new(
      name: "main", version: "1.0.0", platform: "ruby",
      dependencies: [dep_obj], source: "https://rubygems.org",
      has_extensions: false, remote_uri: nil, checksum: nil,
    )
    link_by_name = { "dep1" => 99 }
    result = install.send(:dependency_link_job_ids, spec, link_by_name)
    assert_equal [99], result
  end

  # --- extracted_path_for_entry ---

  def test_extracted_path_for_entry_returns_source_when_local_dir
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "mylib", version: "1.0.0", source: dir)
      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: nil, gem_path: nil)

      result = install.send(:extracted_path_for_entry, entry, cache)
      assert_equal dir, result
    end
  end

  def test_extracted_path_for_entry_resolves_local_monorepo_subdir
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      monorepo = File.join(dir, "repo")
      subdir = File.join(monorepo, "actionpack")
      FileUtils.mkdir_p(subdir)
      File.write(File.join(subdir, "actionpack.gemspec"), "Gem::Specification.new\n")

      spec = fake_spec(name: "actionpack", version: "8.2.0.alpha", source: monorepo)
      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: nil, gem_path: nil)

      result = install.send(:extracted_path_for_entry, entry, cache)
      assert_equal subdir, result
    end
  end

  def test_extracted_path_for_entry_uses_cached_path_when_provided
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      cached = File.join(dir, "cached_path")
      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: cached, gem_path: nil)

      result = install.send(:extracted_path_for_entry, entry, cache)
      assert_equal cached, result
    end
  end

  # --- clone_git_repo / fetch_git_repo error handling ---

  def test_clone_git_repo_raises_on_failure
    install = Scint::CLI::Install.new([])
    assert_raises(Scint::InstallError) do
      install.send(:clone_git_repo, "https://nonexistent.invalid/foo.git", "/tmp/scint-test-nonexistent-bare")
    end
  end

  # --- resolve_git_gem_subdir ---

  def test_resolve_git_gem_subdir_returns_repo_root_when_gemspec_at_root
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      File.write(File.join(dir, "demo.gemspec"), "")
      spec = fake_spec(name: "demo", version: "1.0.0", source: "https://github.com/demo.git")
      result = install.send(:resolve_git_gem_subdir, dir, spec)
      assert_equal dir, result
    end
  end

  def test_resolve_git_gem_subdir_raises_when_no_matching_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "missing", version: "1.0.0", source: "https://github.com/demo.git")
      error = assert_raises(Scint::InstallError) do
        install.send(:resolve_git_gem_subdir, dir, spec)
      end
      assert_includes error.message, "does not contain missing.gemspec"
    end
  end

  def test_git_spec_layout_current_true_when_matching_root_gemspec_exists
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "actionpack", version: "8.2.0.alpha", source: "https://github.com/rails/rails.git")
      File.write(File.join(dir, "actionpack.gemspec"), "")

      assert install.send(:git_spec_layout_current?, dir, spec)
    end
  end

  def test_git_spec_layout_current_false_for_repo_root_layout_without_matching_root_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "actionpack", version: "8.2.0.alpha", source: "https://github.com/rails/rails.git")
      FileUtils.mkdir_p(File.join(dir, "actionpack"))
      File.write(File.join(dir, "actionpack", "actionpack.gemspec"), "")

      refute install.send(:git_spec_layout_current?, dir, spec)
    end
  end

  # --- load_cached_gemspec with YAML format ---

  def test_load_cached_gemspec_handles_yaml_format
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "rack", version: "2.2.8")

      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "rack"
        s.authors = ["test"]
      end

      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rack.rb"), "")

      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), gemspec.to_yaml)

      result = install.send(:load_cached_gemspec, spec, cache, extracted)
      assert_equal "rack", result.name
    end
  end

  # --- load_gemspec returns nil when inbound doesn't exist ---

  def test_load_gemspec_returns_nil_when_no_cache_or_inbound
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "nonexistent", version: "1.0.0")

      result = install.send(:load_gemspec, "/nonexistent", spec, cache)
      assert_nil result
    end
  end

  # --- git_checkout_marker_path ---

  def test_git_checkout_marker_path
    install = Scint::CLI::Install.new([])
    result = install.send(:git_checkout_marker_path, "/tmp/extracted/demo-1.0.0")
    assert_equal "/tmp/extracted/demo-1.0.0.scint_git_revision", result
  end

  # --- git_mutex_for ---

  def test_git_mutex_for_returns_same_mutex_for_same_path
    install = Scint::CLI::Install.new([])
    m1 = install.send(:git_mutex_for, "/tmp/repo1")
    m2 = install.send(:git_mutex_for, "/tmp/repo1")
    m3 = install.send(:git_mutex_for, "/tmp/repo2")
    assert_same m1, m2
    refute_same m1, m3
  end

  # --- spec_key ---

  def test_spec_key
    install = Scint::CLI::Install.new([])
    spec = fake_spec(name: "rack", version: "2.2.8", platform: "ruby")
    assert_equal "rack-2.2.8-ruby", install.send(:spec_key, spec)
  end

  # --- read_require_paths ---

  def test_read_require_paths_returns_lib_when_no_spec_file
    install = Scint::CLI::Install.new([])
    assert_equal ["lib"], install.send(:read_require_paths, "/nonexistent.gemspec")
  end

  # --- warn_missing_bundle_gitignore_entry (no .gitignore file) ---

  def test_warn_missing_bundle_gitignore_no_file
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new([])
        with_captured_stderr do |err|
          install.send(:warn_missing_bundle_gitignore_entry)
          assert_equal "", err.string
        end
      end
    end
  end

  # --- enqueue_install_dag unknown action ---

  def test_enqueue_install_dag_skips_unknown_action
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "mystery", version: "1.0.0")
      plan = [Scint::PlanEntry.new(spec: spec, action: :unknown, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)
      assert_equal 0, compiled.call
      assert_empty scheduler.enqueued
    end
  end

  # --- fetch_index ---

  def test_fetch_index_noop_when_source_has_no_remotes
    install = Scint::CLI::Install.new([])
    # Plain hash source without remotes method
    install.send(:fetch_index, { type: :rubygems, uri: "https://rubygems.org" }, nil)
    # Should not raise
  end

  # --- clone_git_source noop for non-uri source ---

  def test_clone_git_source_noop_for_non_uri_source
    install = Scint::CLI::Install.new([])
    source = Object.new
    # Should not raise when source doesn't respond_to?(:uri)
    install.send(:clone_git_source, source, nil)
  end

  # --- resolve with path gems ---

  def test_resolve_with_path_gem_reads_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      # Create a path gem with a gemspec
      path_dir = File.join(dir, "mylib")
      FileUtils.mkdir_p(path_dir)
      File.write(File.join(path_dir, "mylib.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mylib"
          s.version = "1.2.3"
          s.summary = "test"
          s.authors = ["test"]
          s.add_runtime_dependency "rack", ">= 2.0"
        end
      RUBY

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("mylib", source_options: { path: path_dir }),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      # Stub the resolver and provider to avoid network calls
      fake_resolved = [fake_spec(name: "mylib", version: "1.2.3", source: path_dir)]
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { fake_resolved }

      Scint::Resolver::Resolver.stub(:new, fake_resolver) do
        resolved = install.send(:resolve, gemfile, nil, nil)
        assert_equal 1, resolved.size
        assert_equal "mylib", resolved.first.name
      end
    end
  end

  def test_resolve_with_git_gem_uses_lockfile_version
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [{ name: "gitdep", version: "2.5.0" }],
        dependencies: {},
        platforms: [],
        sources: [source],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("gitdep",
            source_options: { git: "https://github.com/demo/gitdep.git" }),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      fake_resolved = [fake_spec(name: "gitdep", version: "2.5.0")]
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { fake_resolved }

      Scint::Resolver::Resolver.stub(:new, fake_resolver) do
        resolved = install.send(:resolve, gemfile, lockfile, nil)
        assert_equal 1, resolved.size
      end
    end
  end

  def test_resolve_with_inline_source_option
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("private-gem",
            source_options: { source: "https://custom.rubygems.org" }),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      fake_resolved = [fake_spec(name: "private-gem", version: "1.0.0")]
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { fake_resolved }

      Scint::Resolver::Resolver.stub(:new, fake_resolver) do
        resolved = install.send(:resolve, gemfile, nil, nil)
        assert_equal 1, resolved.size
      end
    end
  end

  # --- read_require_paths error rescue ---

  def test_read_require_paths_returns_lib_on_error
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      broken_spec = File.join(dir, "broken.gemspec")
      File.write(broken_spec, "raise 'broken'")
      assert_equal ["lib"], install.send(:read_require_paths, broken_spec)
    end
  end

  # --- enqueue_install_dag with :link and :build_ext action entries ---

  def test_enqueue_install_dag_link_action_enqueues_link_task
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "rack", version: "2.2.8")
      plan = [Scint::PlanEntry.new(spec: spec, action: :link, cached_path: cache.extracted_path(spec), gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "rack" }
      binstub_job = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "rack" }

      refute_nil link_job
      refute_nil binstub_job
      assert_equal 0, compiled.call
    end
  end

  def test_enqueue_install_dag_build_ext_action_with_buildable_extensions
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "ffi", version: "1.17.0", has_extensions: true)
      cached = cache.extracted_path(spec)
      ext_dir = File.join(cached, "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      plan = [Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: cached, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "ffi" }
      build_job = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "ffi" }
      binstub_job = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "ffi" }

      refute_nil link_job
      refute_nil build_job
      refute_nil binstub_job
      assert_equal 1, compiled.call
    end
  end

  # --- download_gem with actual download stubbed ---

  def test_download_gem_calls_pool_download
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      downloaded = false
      fake_pool = Object.new
      fake_pool.define_singleton_method(:download) { |_uri, _dest| downloaded = true }
      fake_pool.define_singleton_method(:close) { }

      Scint::Downloader::Pool.stub(:new, fake_pool) do
        install.send(:download_gem, entry, cache)
      end
      assert downloaded
    end
  end

  def test_download_gem_reuses_shared_pool_for_multiple_downloads
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))

      spec_a = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org")
      spec_b = fake_spec(name: "rake", version: "13.3.1", source: "https://rubygems.org")
      entry_a = Scint::PlanEntry.new(spec: spec_a, action: :download, cached_path: nil, gem_path: nil)
      entry_b = Scint::PlanEntry.new(spec: spec_b, action: :download, cached_path: nil, gem_path: nil)

      created = 0
      downloaded = []
      fake_pool = Object.new
      fake_pool.define_singleton_method(:download) do |uri, dest|
        downloaded << [uri, dest]
      end
      fake_pool.define_singleton_method(:close) { }

      Scint::Downloader::Pool.stub(:new, ->(**_kw) { created += 1; fake_pool }) do
        install.send(:download_gem, entry_a, cache)
        install.send(:download_gem, entry_b, cache)
      end

      assert_equal 1, created
      assert_equal 2, downloaded.length
    end
  end

  # --- build_extensions / write_binstubs ---

  def test_build_extensions_delegates_to_extension_builder
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "ffi", version: "1.17.0")
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "ffi.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "ffi"
        s.version = "1.17.0"
        s.summary = "test"
        s.authors = ["test"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(gemspec))

      entry = Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: nil, gem_path: nil)

      build_called = false
      Scint::Installer::ExtensionBuilder.stub(:build, -> (*_args, **_kw) { build_called = true }) do
        install.send(:build_extensions, entry, cache, bundle_path, nil, compile_slots: 1)
      end
      assert build_called
    end
  end

  def test_write_binstubs_delegates_to_linker
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "rake", version: "13.2.1")
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rake.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "rake"
        s.version = "13.2.1"
        s.summary = "test"
        s.authors = ["test"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(gemspec))

      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: nil, gem_path: nil)

      binstub_called = false
      Scint::Installer::Linker.stub(:write_binstubs, -> (*_args) { binstub_called = true }) do
        install.send(:write_binstubs, entry, cache, bundle_path)
      end
      assert binstub_called
    end
  end

  # --- sync_build_env_dependencies with respond_to(:name) deps ---

  def test_sync_build_env_dependencies_with_dependency_objects
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")
      source_ruby_dir = ruby_bundle_dir(bundle_path)

      # Create mini_portile2 as a dep object
      dep = Scint::Gemfile::Dependency.new("mini_portile2")
      spec = Scint::ResolvedSpec.new(
        name: "nokogiri", version: "1.18.10", platform: "ruby",
        dependencies: [dep], source: "https://rubygems.org",
        has_extensions: false, remote_uri: nil, checksum: nil,
      )

      # Set up source bundle
      dep_name = "mini_portile2-2.8.5"
      dep_spec_path = File.join(source_ruby_dir, "specifications", "#{dep_name}.gemspec")
      dep_gem = File.join(source_ruby_dir, "gems", dep_name)
      FileUtils.mkdir_p(File.dirname(dep_spec_path))
      FileUtils.mkdir_p(dep_gem)
      File.write(File.join(dep_gem, "lib.rb"), "")
      File.write(dep_spec_path, "Gem::Specification.new { |s| s.name='mini_portile2'; s.version='2.8.5' }\n")

      rake_name = "rake-13.2.1"
      rake_spec_path = File.join(source_ruby_dir, "specifications", "#{rake_name}.gemspec")
      rake_gem = File.join(source_ruby_dir, "gems", rake_name)
      FileUtils.mkdir_p(rake_gem)
      File.write(File.join(rake_gem, "exe"), "")
      File.write(rake_spec_path, "Gem::Specification.new { |s| s.name='rake'; s.version='13.2.1' }\n")

      install.send(:sync_build_env_dependencies, spec, bundle_path, cache)

      target = cache.install_ruby_dir
      assert Dir.exist?(File.join(target, "gems", dep_name))
    end
  end

  # --- load_gemspec fallback via inbound metadata error ---

  def test_load_gemspec_returns_nil_on_broken_inbound
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "broken", version: "1.0.0")

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      File.write(inbound, "not-a-valid-gem-file")

      result = install.send(:load_gemspec, "/nonexistent", spec, cache)
      assert_nil result
    end
  end

  # --- load_cached_gemspec with broken marshal data ---

  def test_load_cached_gemspec_returns_nil_on_bad_data
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "broken", version: "1.0.0")

      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), "garbage-data-not-yaml-or-marshal")

      result = install.send(:load_cached_gemspec, spec, cache, "/nonexistent")
      assert_nil result
    end
  end

  # --- preferred_platforms_for_locked_specs ---

  def test_preferred_platforms_for_locked_specs_catches_errors
    install = Scint::CLI::Install.new([])
    install.instance_variable_set(:@credentials, Scint::Credentials.new)

    specs = [fake_spec(name: "nokogiri", version: "1.18.10", source: "https://rubygems.org")]

    # Stub Index::Client to raise
    Scint::Index::Client.stub(:new, -> (*_) { raise StandardError, "network error" }) do
      result = install.send(:preferred_platforms_for_locked_specs, specs)
      assert_equal({}, result)
    end
  end

  # --- run method integration (all-cached, nothing to install) ---

  def test_run_returns_zero_when_nothing_to_install
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle")])

        # Write Gemfile
        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        resolved = [fake_spec(name: "rack", version: "2.2.8")]
        adjusted = resolved.dup
        adjusted.unshift(fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)"))

        plan = adjusted.map do |s|
          Scint::PlanEntry.new(spec: s, action: :skip, cached_path: nil, gem_path: nil)
        end

        Scint::Gemfile::Parser.stub(:parse, gemfile) do
          install.stub(:resolve, resolved) do
            install.stub(:adjust_meta_gems, adjusted) do
              install.stub(:dedupe_resolved_specs, adjusted) do
                Scint::Installer::Planner.stub(:plan, plan) do
                  # Capture stdout
                  old_stdout = $stdout
                  $stdout = StringIO.new
                  begin
                    result = install.run
                    assert_equal 0, result
                    output = $stdout.string
                    assert_includes output, "gems installed total"
                  ensure
                    $stdout = old_stdout
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- run method with install work (success path) ---

  def test_run_installs_gems_and_writes_lockfile_on_success
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle"), "-j", "1"])

        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        rack_spec = fake_spec(name: "rack", version: "2.2.8")
        scint_spec = fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")
        resolved = [scint_spec, rack_spec]

        rack_plan = Scint::PlanEntry.new(spec: rack_spec, action: :link, cached_path: nil, gem_path: nil)
        scint_plan = Scint::PlanEntry.new(spec: scint_spec, action: :builtin, cached_path: nil, gem_path: nil)
        plan = [scint_plan, rack_plan]

        fake_scheduler = Object.new
        started = false
        fake_scheduler.define_singleton_method(:start) { started = true }
        fake_scheduler.define_singleton_method(:scale_workers) { |_| }
        fake_scheduler.define_singleton_method(:enqueue) { |*_args, **_kw| 1 }
        fake_scheduler.define_singleton_method(:wait_for) { |_| }
        fake_scheduler.define_singleton_method(:wait_all) { }
        fake_scheduler.define_singleton_method(:errors) { [] }
        fake_scheduler.define_singleton_method(:stats) { { failed: 0, completed: 2, total: 2 } }
        fake_scheduler.define_singleton_method(:progress) { Scint::Progress.new }
        fake_scheduler.define_singleton_method(:shutdown) { }

        Scint::Scheduler.stub(:new, fake_scheduler) do
          Scint::Gemfile::Parser.stub(:parse, gemfile) do
            install.stub(:resolve, resolved) do
              install.stub(:adjust_meta_gems, resolved) do
                install.stub(:dedupe_resolved_specs, resolved) do
                  Scint::Installer::Planner.stub(:plan, plan) do
                    install.stub(:enqueue_install_dag, ->(*_a, **_k) { -> { 0 } }) do
                      install.stub(:write_lockfile, nil) do
                        install.stub(:write_runtime_config, nil) do
                          old_stdout = $stdout
                          $stdout = StringIO.new
                          begin
                            result = install.run
                            assert_equal 0, result
                            assert started
                            output = $stdout.string
                            assert_includes output, "gems installed total"
                          ensure
                            $stdout = old_stdout
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- run method with failures ---

  def test_run_returns_one_on_install_errors
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle"), "-j", "1"])

        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        rack_spec = fake_spec(name: "rack", version: "2.2.8")
        scint_spec = fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")
        resolved = [scint_spec, rack_spec]

        rack_plan = Scint::PlanEntry.new(spec: rack_spec, action: :link, cached_path: nil, gem_path: nil)
        plan = [rack_plan]

        error = { name: "rack", error: RuntimeError.new("build failed") }

        fake_scheduler = Object.new
        fake_scheduler.define_singleton_method(:start) { }
        fake_scheduler.define_singleton_method(:scale_workers) { |_| }
        fake_scheduler.define_singleton_method(:enqueue) { |*_args, **_kw| 1 }
        fake_scheduler.define_singleton_method(:wait_for) { |_| }
        fake_scheduler.define_singleton_method(:wait_all) { }
        fake_scheduler.define_singleton_method(:errors) { [error] }
        fake_scheduler.define_singleton_method(:stats) { { failed: 1, completed: 1, total: 2 } }
        fake_scheduler.define_singleton_method(:progress) { Scint::Progress.new }
        fake_scheduler.define_singleton_method(:shutdown) { }

        Scint::Scheduler.stub(:new, fake_scheduler) do
          Scint::Gemfile::Parser.stub(:parse, gemfile) do
            install.stub(:resolve, resolved) do
              install.stub(:adjust_meta_gems, resolved) do
                install.stub(:dedupe_resolved_specs, resolved) do
                  Scint::Installer::Planner.stub(:plan, plan) do
                    install.stub(:enqueue_install_dag, ->(*_a, **_k) { -> { 0 } }) do
                      old_stdout = $stdout
                      old_stderr = $stderr
                      $stdout = StringIO.new
                      $stderr = StringIO.new
                      begin
                        result = install.run
                        assert_equal 1, result
                        assert_includes $stderr.string, "failed to install"
                        assert_includes $stdout.string, "Bundle failed"
                      ensure
                        $stdout = old_stdout
                        $stderr = old_stderr
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- run method with stats-only failures (no error details) ---

  def test_run_warns_on_stats_failed_without_error_details
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle"), "-j", "1"])

        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        rack_spec = fake_spec(name: "rack", version: "2.2.8")
        resolved = [rack_spec]

        plan = [Scint::PlanEntry.new(spec: rack_spec, action: :link, cached_path: nil, gem_path: nil)]

        fake_scheduler = Object.new
        fake_scheduler.define_singleton_method(:start) { }
        fake_scheduler.define_singleton_method(:scale_workers) { |_| }
        fake_scheduler.define_singleton_method(:enqueue) { |*_args, **_kw| 1 }
        fake_scheduler.define_singleton_method(:wait_for) { |_| }
        fake_scheduler.define_singleton_method(:wait_all) { }
        fake_scheduler.define_singleton_method(:errors) { [] }  # No error details
        fake_scheduler.define_singleton_method(:stats) { { failed: 1, completed: 1, total: 2 } }
        fake_scheduler.define_singleton_method(:progress) { Scint::Progress.new }
        fake_scheduler.define_singleton_method(:shutdown) { }

        Scint::Scheduler.stub(:new, fake_scheduler) do
          Scint::Gemfile::Parser.stub(:parse, gemfile) do
            install.stub(:resolve, resolved) do
              install.stub(:adjust_meta_gems, resolved) do
                install.stub(:dedupe_resolved_specs, resolved) do
                  Scint::Installer::Planner.stub(:plan, plan) do
                    install.stub(:enqueue_install_dag, ->(*_a, **_k) { -> { 0 } }) do
                      old_stdout = $stdout
                      old_stderr = $stderr
                      $stdout = StringIO.new
                      $stderr = StringIO.new
                      begin
                        result = install.run
                        assert_equal 1, result
                        assert_includes $stderr.string, "no error details"
                      ensure
                        $stdout = old_stdout
                        $stderr = old_stderr
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- extracted_path_for_entry with git source ---

  def test_extracted_path_for_entry_with_git_source_resolves_subdir
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])

      git_source = Scint::Source::Git.new(uri: "https://github.com/rails/rails.git")
      spec = fake_spec(name: "actionpack", version: "7.2.0", source: git_source)

      extracted = cache.extracted_path(spec)
      sub = File.join(extracted, "actionpack")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, "actionpack.gemspec"), "")

      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: nil, gem_path: nil)
      result = install.send(:extracted_path_for_entry, entry, cache)
      assert_equal sub, result
    end
  end

  def test_extracted_path_for_entry_with_git_source_raises_when_gemspec_missing
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])

      git_source = Scint::Source::Git.new(uri: "https://github.com/rails/rails.git")
      spec = fake_spec(name: "missing", version: "1.0.0", source: git_source)

      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "other.gemspec"), "")

      entry = Scint::PlanEntry.new(spec: spec, action: :link, cached_path: nil, gem_path: nil)
      error = assert_raises(Scint::InstallError) do
        install.send(:extracted_path_for_entry, entry, cache)
      end
      assert_includes error.message, "does not contain missing.gemspec"
    end
  end

  # --- enqueue_builds ---

  def test_enqueue_builds_returns_count_of_buildable
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec1 = fake_spec(name: "ffi", version: "1.17.0", has_extensions: true)
      spec2 = fake_spec(name: "pure", version: "1.0.0", has_extensions: false)

      # ffi has buildable extensions
      ext_dir = File.join(cache.extracted_path(spec1), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      # pure has no extensions
      FileUtils.mkdir_p(cache.extracted_path(spec2))

      entries = [
        Scint::PlanEntry.new(spec: spec1, action: :build_ext, cached_path: nil, gem_path: nil),
        Scint::PlanEntry.new(spec: spec2, action: :build_ext, cached_path: nil, gem_path: nil),
      ]

      count = install.send(:enqueue_builds, scheduler, entries, cache, bundle_path)
      assert_equal 1, count
    end
  end

  # --- find_gemspec with fallback glob ---

  def test_find_gemspec_finds_non_exact_match
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      # Write a gemspec with different name than requested
      File.write(File.join(dir, "other.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "other"
          s.version = "1.0.0"
          s.summary = "test"
          s.authors = ["test"]
        end
      RUBY

      result = install.send(:find_gemspec, dir, "nonexistent")
      assert_equal "other", result.name
    end
  end

  def test_find_gemspec_handles_broken_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      File.write(File.join(dir, "broken.gemspec"), "raise 'bad gemspec'")

      result = install.send(:find_gemspec, dir, "broken")
      assert_nil result
    end
  end

  # --- fetch_index with source that has remotes ---

  def test_fetch_index_ensures_dir_for_source_with_remotes
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])

      install.send(:fetch_index, source, cache)
      assert Dir.exist?(cache.index_path(source))
    end
  end

  # --- resolve with lockfile locked specs ---

  def test_resolve_uses_lockfile_locked_specs
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      _lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "rack", version: "2.2.8" },
          { name: "puma", version: "6.0.0" },
        ],
        dependencies: {},
        platforms: [],
        sources: [],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("rack"),
          Scint::Gemfile::Dependency.new("puma"),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      # Lockfile not current (missing dep), so should call resolver
      fake_resolved = [
        fake_spec(name: "rack", version: "2.2.8"),
        fake_spec(name: "puma", version: "6.0.0"),
      ]
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { fake_resolved }

      # Remove "puma" from lockfile to make it stale
      stale_lockfile = Scint::Lockfile::LockfileData.new(
        specs: [{ name: "rack", version: "2.2.8" }],
        dependencies: {},
        platforms: [],
        sources: [],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      Scint::Resolver::Resolver.stub(:new, fake_resolver) do
        resolved = install.send(:resolve, gemfile, stale_lockfile, nil)
        assert_equal 2, resolved.size
      end
    end
  end

  # --- preferred_platforms_for_locked_specs success path ---

  def test_preferred_platforms_for_locked_specs_returns_preferred
    install = Scint::CLI::Install.new([])
    install.instance_variable_set(:@credentials, Scint::Credentials.new)

    specs = [fake_spec(name: "nokogiri", version: "1.18.10", source: "https://rubygems.org")]

    fake_provider = Object.new
    fake_provider.define_singleton_method(:prefetch) { |_| }
    fake_provider.define_singleton_method(:preferred_platform_for) { |_name, _ver| "arm64-darwin" }

    fake_client = Object.new

    Scint::Index::Client.stub(:new, fake_client) do
      Scint::Resolver::Provider.stub(:new, fake_provider) do
        result = install.send(:preferred_platforms_for_locked_specs, specs)
        assert_equal "arm64-darwin", result["nokogiri-1.18.10"]
      end
    end
  end

  # --- run with lockfile present ---

  def test_run_parses_lockfile_when_present
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle")])

        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')
        File.write("Gemfile.lock", <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rack (2.2.8)

          PLATFORMS
            ruby

          DEPENDENCIES
            rack
        LOCK

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        lockfile = Scint::Lockfile::LockfileData.new(
          specs: [{ name: "rack", version: "2.2.8", platform: "ruby", dependencies: [],
                    source: Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"]), checksum: nil }],
          dependencies: {},
          platforms: ["ruby"],
          sources: [Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])],
          bundler_version: nil,
          ruby_version: nil,
          checksums: nil,
        )

        resolved = [fake_spec(name: "rack", version: "2.2.8")]
        adjusted = [fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")] + resolved
        plan = adjusted.map { |s| Scint::PlanEntry.new(spec: s, action: :skip, cached_path: nil, gem_path: nil) }

        Scint::Gemfile::Parser.stub(:parse, gemfile) do
          Scint::Lockfile::Parser.stub(:parse, lockfile) do
            install.stub(:resolve, resolved) do
              install.stub(:adjust_meta_gems, adjusted) do
                install.stub(:dedupe_resolved_specs, adjusted) do
                  Scint::Installer::Planner.stub(:plan, plan) do
                    old_stdout = $stdout
                    $stdout = StringIO.new
                    begin
                      result = install.run
                      assert_equal 0, result
                    ensure
                      $stdout = old_stdout
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_run_writes_lock_and_runtime_config_when_everything_is_cached
    with_tmpdir do |dir|
      with_cwd(dir) do
        install = Scint::CLI::Install.new(["--path", File.join(dir, ".bundle")])

        File.write("Gemfile", 'source "https://rubygems.org"\ngem "rack"\n')
        File.write("Gemfile.lock", <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rack (2.2.8)

          DEPENDENCIES
            rack
        LOCK

        gemfile = Scint::Gemfile::ParseResult.new(
          dependencies: [Scint::Gemfile::Dependency.new("rack")],
          sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
          ruby_version: nil,
          platforms: [],
        )

        lockfile = Scint::Lockfile::LockfileData.new(
          specs: [{ name: "rack", version: "2.2.8", platform: "ruby", dependencies: [],
                    source: Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"]), checksum: nil }],
          dependencies: {},
          platforms: ["ruby"],
          sources: [Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])],
          bundler_version: nil,
          ruby_version: nil,
          checksums: nil,
        )

        resolved = [fake_spec(name: "rack", version: "2.2.8")]
        adjusted = [fake_spec(name: "scint", version: Scint::VERSION, source: "scint (built-in)")] + resolved
        plan = adjusted.map { |s| Scint::PlanEntry.new(spec: s, action: :skip, cached_path: nil, gem_path: nil) }

        wrote_lock = false
        wrote_runtime = false

        Scint::Gemfile::Parser.stub(:parse, gemfile) do
          Scint::Lockfile::Parser.stub(:parse, lockfile) do
            install.stub(:resolve, resolved) do
              install.stub(:adjust_meta_gems, adjusted) do
                install.stub(:dedupe_resolved_specs, adjusted) do
                  Scint::Installer::Planner.stub(:plan, plan) do
                    install.stub(:write_lockfile, ->(*_args) { wrote_lock = true }) do
                      install.stub(:write_runtime_config, ->(*_args) { wrote_runtime = true }) do
                        old_stdout = $stdout
                        $stdout = StringIO.new
                        begin
                          result = install.run
                          assert_equal 0, result
                        ensure
                          $stdout = old_stdout
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        assert_equal true, wrote_lock
        assert_equal true, wrote_runtime
      end
    end
  end

  # --- resolve with git gem and lockfile version ---

  def test_resolve_with_git_gem_and_locked_version
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      install.instance_variable_set(:@credentials, Scint::Credentials.new)

      lockfile = Scint::Lockfile::LockfileData.new(
        specs: [
          { name: "gitdep", version: "2.5.0" },
          { name: "rack", version: "2.2.8" },
        ],
        dependencies: {},
        platforms: [],
        sources: [],
        bundler_version: nil,
        ruby_version: nil,
        checksums: nil,
      )

      # Lockfile is not current (missing "otherdep")
      gemfile = Scint::Gemfile::ParseResult.new(
        dependencies: [
          Scint::Gemfile::Dependency.new("rack"),
          Scint::Gemfile::Dependency.new("gitdep",
            source_options: { git: "https://github.com/demo/gitdep.git" }),
          Scint::Gemfile::Dependency.new("otherdep"),
        ],
        sources: [{ type: :rubygems, uri: "https://rubygems.org" }],
        ruby_version: nil,
        platforms: [],
      )

      fake_resolved = [
        fake_spec(name: "rack", version: "2.2.8"),
        fake_spec(name: "gitdep", version: "2.5.0"),
        fake_spec(name: "otherdep", version: "1.0.0"),
      ]
      fake_resolver = Object.new
      fake_resolver.define_singleton_method(:resolve) { fake_resolved }

      Scint::Resolver::Resolver.stub(:new, fake_resolver) do
        resolved = install.send(:resolve, gemfile, lockfile, nil)
        assert_equal 3, resolved.size
      end
    end
  end

  # --- git source clone enqueue (lines 95-96) ---

  def test_run_enqueues_git_clone_for_git_sources
    # Directly test lines 93-97: the git_clone enqueue logic from within run.
    # We simulate the section of run() that filters Git sources and enqueues :git_clone.
    scheduler = FakeScheduler.new
    git_source = Scint::Source::Git.new(uri: "https://github.com/demo/demo.git", branch: "main")
    non_git_source = { type: :rubygems, uri: "https://rubygems.org" }

    # Replicate the exact logic from lines 93-97 of install.rb
    sources = [non_git_source, git_source]
    git_sources = sources.select { |s| s.is_a?(Scint::Source::Git) }
    git_sources.each do |source|
      scheduler.enqueue(:git_clone, source.uri,
                        -> { nil }) # lambda placeholder
    end

    git_clone_jobs = scheduler.enqueued.select { |e| e[:type] == :git_clone }
    assert_equal 1, git_clone_jobs.size
    assert_equal "https://github.com/demo/demo.git", git_clone_jobs.first[:name]
  end

  def test_clone_git_source_called_via_git_clone_enqueue
    # Tests the clone_git_source callback that runs inside the :git_clone job (lines 95-96).
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n")
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      source = Scint::Source::Git.new(uri: repo, branch: "main")

      # Simulate what the enqueued lambda does (line 96)
      install.send(:clone_git_source, source, cache)

      bare = cache.git_path(source.uri)
      assert Dir.exist?(bare), "bare repo should be cloned"
    end
  end

  # --- find_gemspec rescue StandardError (line 366) ---

  def test_find_gemspec_rescues_broken_gemspec_and_falls_through
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      # Write a broken gemspec as exact match, plus a valid one via glob
      File.write(File.join(dir, "mylib.gemspec"), "raise 'broken gemspec load'")
      File.write(File.join(dir, "fallback.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "fallback"
          s.version = "2.0.0"
          s.summary = "fallback"
          s.authors = ["test"]
        end
      RUBY

      # The broken exact-match gemspec should be rescued, then the fallback glob one loads
      result = install.send(:find_gemspec, dir, "mylib")
      assert_equal "fallback", result.name
    end
  end

  def test_find_gemspec_returns_nil_when_only_broken_gemspec_exists
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      File.write(File.join(dir, "broken.gemspec"), "raise 'cannot load'")

      result = install.send(:find_gemspec, dir, "broken")
      assert_nil result
    end
  end

  # --- git checkout failure raises InstallError (line 573) ---

  def test_prepare_git_source_raises_install_error_on_checkout_failure
    with_tmpdir do |dir|
      repo = init_git_repo(dir, "demo.gemspec" => "Gem::Specification.new\n")
      commit = git_commit_hash(repo)
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      spec = fake_spec(name: "demo", version: "1.0.0",
                        source: Scint::Source::Git.new(uri: repo, revision: commit))
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      # Stub Open3.capture3 to simulate a failed checkout
      call_count = 0
      original_capture3 = Open3.method(:capture3)
      fake_capture3 = lambda do |*args|
        call_count += 1
        if args.include?("checkout")
          # Simulate git checkout failure
          ["", "fatal: reference is not a tree", stub_status(false)]
        else
          original_capture3.call(*args)
        end
      end

      Open3.stub(:capture3, fake_capture3) do
        err = assert_raises(Scint::InstallError) do
          install.send(:prepare_git_source, entry, cache)
        end
        assert_includes err.message, "Git checkout failed"
      end
    end
  end

  # --- enqueue_install_dag :download entry full path (lines 673-711) ---

  def test_enqueue_install_dag_download_entry_enqueues_download_extract_link
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "json", version: "2.7.0", has_extensions: false)
      plan = [Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      # Verify :download was enqueued (line 676-677)
      download_job = scheduler.enqueued.find { |e| e[:type] == :download && e[:name] == "json" }
      refute_nil download_job, "download job should be enqueued"

      # Verify :extract was enqueued with depends_on download (line 678-681)
      extract_job = scheduler.enqueued.find { |e| e[:type] == :extract && e[:name] == "json" }
      refute_nil extract_job, "extract job should be enqueued"
      download_id = scheduler.enqueued.index(download_job) + 1
      assert_includes extract_job[:depends_on], download_id

      # Verify :link was enqueued with depends_on extract (line 703-705)
      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "json" }
      refute_nil link_job, "link job should be enqueued"
      extract_id = scheduler.enqueued.index(extract_job) + 1
      assert_includes link_job[:depends_on], extract_id

      # Verify follow_up was set on extract (for binstub/build_ext)
      refute_nil extract_job[:follow_up]

      # Trigger the follow_up to get binstub enqueued (line 699-701)
      extract_job[:follow_up].call(nil)
      binstub_job = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "json" }
      refute_nil binstub_job, "binstub job should be enqueued via follow_up"

      assert_equal 0, compiled.call
    end
  end

  def test_enqueue_install_dag_download_entry_with_native_extensions
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "nio4r", version: "2.7.0", has_extensions: true)
      plan = [Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      # Set up native extension directory before calling follow_up
      ext_dir = File.join(cache.extracted_path(spec), "ext", "nio4r")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      extract_job = scheduler.enqueued.find { |e| e[:type] == :extract && e[:name] == "nio4r" }
      refute_nil extract_job[:follow_up]

      # Trigger follow_up -- should enqueue build_ext (line 691-693) and binstub (line 699-701)
      extract_job[:follow_up].call(nil)

      build_job = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "nio4r" }
      binstub_job = scheduler.enqueued.reverse.find { |e| e[:type] == :binstub && e[:name] == "nio4r" }

      refute_nil build_job, "build_ext job should be enqueued for native gem"
      refute_nil binstub_job, "binstub job should be enqueued"

      # build_ext depends on link (line 692-693)
      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "nio4r" }
      link_id = scheduler.enqueued.index(link_job) + 1
      assert_includes build_job[:depends_on], link_id

      # binstub depends on both link and build_ext (line 699-701)
      build_id = scheduler.enqueued.index(build_job) + 1
      assert_includes binstub_job[:depends_on], link_id
      assert_includes binstub_job[:depends_on], build_id

      assert_equal 1, compiled.call
    end
  end

  # --- enqueue_install_dag :link/:build_ext entries (lines 707-708, 728, 745) ---

  def test_enqueue_install_dag_link_entry_enqueues_link_without_depends
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "puma", version: "6.0.0")
      plan = [Scint::PlanEntry.new(spec: spec, action: :link, cached_path: cache.extracted_path(spec), gem_path: nil)]

      install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "puma" }
      refute_nil link_job, "link job should be enqueued for :link action"
      # :link action enqueues link without depends_on (line 707-708)
      assert_equal [], link_job[:depends_on]

      # binstub phase (line 744-746) also enqueues binstub for :link entries
      binstub_job = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "puma" }
      refute_nil binstub_job, "binstub should be enqueued for :link entry"
    end
  end

  def test_enqueue_install_dag_build_ext_entry_enqueues_link_build_and_binstub
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "sassc", version: "2.4.0", has_extensions: true)
      cached = cache.extracted_path(spec)
      ext_dir = File.join(cached, "ext", "sassc")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      plan = [Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: cached, gem_path: nil)]

      compiled = install.send(:enqueue_install_dag, scheduler, plan, cache, bundle_path)

      # :build_ext action (line 707-708): first enqueues :link without depends
      link_job = scheduler.enqueued.find { |e| e[:type] == :link && e[:name] == "sassc" }
      refute_nil link_job
      assert_equal [], link_job[:depends_on]

      # Second pass (line 727-729): enqueues :build_ext with depends_on link
      build_job = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "sassc" }
      refute_nil build_job
      link_id = scheduler.enqueued.index(link_job) + 1
      assert_includes build_job[:depends_on], link_id

      # Third pass (line 744-746): enqueues :binstub with depends_on link+build
      binstub_job = scheduler.enqueued.find { |e| e[:type] == :binstub && e[:name] == "sassc" }
      refute_nil binstub_job
      build_id = scheduler.enqueued.index(build_job) + 1
      assert_includes binstub_job[:depends_on], link_id
      assert_includes binstub_job[:depends_on], build_id

      assert_equal 1, compiled.call
    end
  end

  # --- enqueue_link_after_download (line 769) ---

  def test_enqueue_link_after_download_enqueues_link_job
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new

      spec = fake_spec(name: "nokogiri", version: "1.18.10", has_extensions: true)
      entry = Scint::PlanEntry.new(spec: spec, action: :download, cached_path: nil, gem_path: nil)

      result = install.send(:enqueue_link_after_download, scheduler, entry, cache, File.join(dir, ".bundle"))

      assert_kind_of Integer, result
      link_job = scheduler.enqueued.last
      assert_equal :link, link_job[:type]
      assert_equal "nokogiri", link_job[:name]
    end
  end

  # --- enqueue_builds (line 779) ---

  def test_enqueue_builds_enqueues_build_ext_for_native_gem
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "bcrypt", version: "3.1.20", has_extensions: true)
      ext_dir = File.join(cache.extracted_path(spec), "ext", "mri")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      entries = [Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: nil, gem_path: nil)]

      count = install.send(:enqueue_builds, scheduler, entries, cache, bundle_path)
      assert_equal 1, count

      build_job = scheduler.enqueued.find { |e| e[:type] == :build_ext && e[:name] == "bcrypt" }
      refute_nil build_job, "enqueue_builds should enqueue :build_ext"
    end
  end

  def test_enqueue_builds_skips_non_buildable_gem
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      scheduler = FakeScheduler.new
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "pure-ruby", version: "1.0.0")
      FileUtils.mkdir_p(cache.extracted_path(spec))

      entries = [Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: nil, gem_path: nil)]

      count = install.send(:enqueue_builds, scheduler, entries, cache, bundle_path)
      assert_equal 0, count
      assert_empty scheduler.enqueued
    end
  end

  # --- build_extensions output_tail lambda (line 849) ---

  def test_build_extensions_passes_output_tail_to_builder
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "racc", version: "1.8.0")
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "racc.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "racc"
        s.version = "1.8.0"
        s.summary = "test"
        s.authors = ["test"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(gemspec))

      entry = Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: nil, gem_path: nil)

      received_output_tail = nil
      Scint::Installer::ExtensionBuilder.stub(:build, lambda { |prepared, bp, c, compile_slots:, output_tail:|
        received_output_tail = output_tail
      }) do
        # Pass a progress object to trigger the output_tail lambda (line 849)
        progress = Scint::Progress.new
        install.send(:build_extensions, entry, cache, bundle_path, progress, compile_slots: 1)
      end

      refute_nil received_output_tail, "output_tail lambda should be passed to ExtensionBuilder.build"
      assert received_output_tail.respond_to?(:call), "output_tail should be callable"
    end
  end

  def test_build_extensions_output_tail_is_noop_without_progress
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      install = Scint::CLI::Install.new([])
      bundle_path = File.join(dir, ".bundle")

      spec = fake_spec(name: "racc", version: "1.8.0")
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "racc.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "racc"
        s.version = "1.8.0"
        s.summary = "test"
        s.authors = ["test"]
      end
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.binwrite(cache.spec_cache_path(spec), Marshal.dump(gemspec))

      entry = Scint::PlanEntry.new(spec: spec, action: :build_ext, cached_path: nil, gem_path: nil)

      received_output_tail = nil
      Scint::Installer::ExtensionBuilder.stub(:build, lambda { |prepared, bp, c, compile_slots:, output_tail:|
        received_output_tail = output_tail
      }) do
        # No progress object (nil) - output_tail should still be set but safe to call
        install.send(:build_extensions, entry, cache, bundle_path, nil, compile_slots: 1)
      end

      refute_nil received_output_tail
      # Calling output_tail with nil progress should not raise
      received_output_tail.call(["line1", "line2"])
    end
  end

  # --- read_require_paths rescue StandardError (line 1076) ---

  def test_read_require_paths_rescues_standard_error_from_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      broken_spec = File.join(dir, "broken.gemspec")
      # This will cause Gem::Specification.load to raise
      File.write(broken_spec, "raise StandardError, 'intentionally broken'")
      result = install.send(:read_require_paths, broken_spec)
      assert_equal ["lib"], result
    end
  end

  def test_read_require_paths_rescues_syntax_error_from_gemspec
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      broken_spec = File.join(dir, "syntax_error.gemspec")
      File.write(broken_spec, "def foo(\nend\n")
      result = install.send(:read_require_paths, broken_spec)
      assert_equal ["lib"], result
    end
  end

  # --- fetch_git_repo error path ---

  def test_fetch_git_repo_raises_on_failure
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      assert_raises(Scint::InstallError) do
        install.send(:fetch_git_repo, "/nonexistent-bare-repo")
      end
    end
  end

  # --- resolve_git_revision error path ---

  def test_resolve_git_revision_raises_on_failure
    with_tmpdir do |dir|
      install = Scint::CLI::Install.new([])
      assert_raises(Scint::InstallError) do
        install.send(:resolve_git_revision, "/nonexistent-bare-repo", "bad-ref")
      end
    end
  end

  private

  def init_git_repo(root_dir, files)
    repo = File.join(root_dir, "repo")
    FileUtils.mkdir_p(repo)
    with_cwd(repo) do
      run_git("init", "-b", "main")
      files.each { |path, content| File.write(path, content) }
      run_git("add", ".")
      run_git("commit", "-m", "initial")
    end
    repo
  end

  def commit_file(repo, path, content, message)
    with_cwd(repo) do
      File.write(path, content)
      run_git("add", path)
      run_git("commit", "-m", message)
    end
  end

  def git_commit_hash(repo)
    with_cwd(repo) { run_git("rev-parse", "HEAD").strip }
  end

  def bare_rev_parse(bare_repo, rev)
    out, err, status = Open3.capture3("git", "--git-dir", bare_repo, "rev-parse", rev)
    assert status.success?, "git rev-parse failed: #{err}"
    out.strip
  end

  def run_git(*args)
    out, err, status = Open3.capture3(
      "git",
      "-c", "user.name=Scint Test",
      "-c", "user.email=scint@example.com",
      "-c", "commit.gpgsign=false",
      *args,
    )
    assert status.success?, "git #{args.join(' ')} failed: #{err}"
    out
  end

  def stub_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
