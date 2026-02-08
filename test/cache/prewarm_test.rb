# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/prewarm"
require "scint/cache/layout"
require "scint/source/git"

class CachePrewarmTest < Minitest::Test
  class FakeDownloader
    attr_reader :items

    def initialize(result_proc)
      @result_proc = result_proc
      @items = nil
    end

    def download_batch(items)
      @items = items
      @result_proc.call(items)
    end

    def close; end
  end

  def test_run_downloads_and_extracts_rubygems_specs
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          create_fake_gem(item[:dest], name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "module Rack; end\n" })
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 2,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 1, result[:warmed]
      assert_equal 0, result[:failed]
      assert File.exist?(cache.inbound_path(spec))
      assert Dir.exist?(cache.cached_path(spec))
      assert File.exist?(cache.cached_spec_path(spec))
      assert File.exist?(cache.cached_manifest_path(spec))
      refute Dir.exist?(cache.extracted_path(spec))
      assert_equal 1, downloader.items.size
    end
  end

  def test_run_skips_when_artifacts_already_exist
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      cached_dir = cache.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached_dir, "lib"))
      File.write(File.join(cached_dir, "lib", "rack.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "rack"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.cached_spec_path(spec)))
      File.binwrite(cache.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached_dir,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "rubygems", "uri" => "https://rubygems.org/" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(cache.cached_manifest_path(spec), manifest)

      downloader = FakeDownloader.new(->(_items) { flunk("should not download") })
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:skipped]
      assert_equal 0, result[:failed]
    end
  end

  def test_run_reports_failed_downloads
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      downloader = FakeDownloader.new(lambda do |items|
        items.map do |item|
          { spec: item[:spec], path: nil, size: 0, error: Scint::NetworkError.new("nope") }
        end
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:failed]
      assert_includes result[:failures].first[:error].message, "nope"
    end
  end

  def test_run_ignores_non_http_sources
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "local", version: "1.0.0", source: "/tmp/local")

      downloader = FakeDownloader.new(->(_items) { flunk("should not download") })
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:ignored]
      assert_equal 0, result[:failed]
    end
  end

  def test_run_force_purges_and_redownloads
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      # Pre-populate cache artifacts
      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      cached_dir = cache.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached_dir, "lib"))
      File.write(File.join(cached_dir, "lib", "rack.rb"), "old")

      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "rack"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.cached_spec_path(spec)))
      File.binwrite(cache.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached_dir,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "rubygems", "uri" => "https://rubygems.org/" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(cache.cached_manifest_path(spec), manifest)

      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          create_fake_gem(item[:dest], name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "new\n" })
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        force: true,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 1, result[:warmed]
      assert_equal 0, result[:skipped]
    end
  end

  def test_run_extract_failure_reports_error
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "broken", version: "1.0.0", source: "https://rubygems.org/")

      # Download succeeds but write a broken file so extraction will fail
      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          File.binwrite(item[:dest], "not-a-valid-gem")
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])
      assert result[:failed] >= 1
      assert result[:failures].any? { |f| f[:spec] == spec }
    end
  end

  def test_default_downloader_factory_creates_pool
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      # Use default factory (no downloader_factory: arg) so line 24 is hit
      prewarm = Scint::Cache::Prewarm.new(cache_layout: cache, jobs: 1)

      # The default factory should create a Downloader::Pool.
      # We call the factory directly to verify it works.
      factory = prewarm.instance_variable_get(:@downloader_factory)
      pool = factory.call(1, nil)
      assert_kind_of Scint::Downloader::Pool, pool
      pool.close
    end
  end

  def test_extract_raises_cache_error_when_inbound_gem_missing
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "missing", version: "1.0.0", source: "https://rubygems.org/")

      # Download "succeeds" but the file doesn't actually exist on disk
      downloader = FakeDownloader.new(lambda do |items|
        # Do NOT write any file -- simulate missing inbound
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 0, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      # The extract worker should have raised CacheError for missing inbound (line 130)
      assert_equal 1, result[:failed]
      assert result[:failures].any? { |f|
        f[:error].is_a?(Scint::CacheError) && f[:error].message.include?("Missing downloaded gem")
      }
    end
  end

  def test_extract_promotes_to_cached_with_manifest
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      # Pre-populate inbound gem
      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { flunk("should not download") },
      )

      task = Scint::Cache::Prewarm::Task.new(spec: spec, download: false, extract: true)
      failures = prewarm.send(:extract_tasks, [task])

      assert_empty failures
      assert Dir.exist?(cache.cached_path(spec)), "cached dir should exist after promotion"
      assert File.exist?(cache.cached_spec_path(spec)), "cached spec should exist"
      assert File.exist?(cache.cached_manifest_path(spec)), "manifest should exist"
      refute Dir.exist?(cache.assembling_path(spec)), "assembling dir should be cleaned up"
    end
  end

  # -- Git source tests ------------------------------------------------------

  def test_run_clones_and_assembles_git_spec
    with_tmpdir do |dir|
      # Create a real git repo with a gemspec
      repo_dir = File.join(dir, "mygem-repo")
      FileUtils.mkdir_p(repo_dir)
      File.write(File.join(repo_dir, "mygem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.version = "1.0.0"
          s.summary = "test"
          s.authors = ["test"]
          s.files = ["lib/mygem.rb"]
          s.require_paths = ["lib"]
        end
      RUBY
      FileUtils.mkdir_p(File.join(repo_dir, "lib"))
      File.write(File.join(repo_dir, "lib", "mygem.rb"), "module Mygem; end\n")
      system("git", "-C", repo_dir, "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "init", out: File::NULL, err: File::NULL)
      revision = `git -C #{repo_dir} rev-parse HEAD`.strip

      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      git_source = Scint::Source::Git.new(uri: repo_dir, revision: revision)
      spec = fake_spec(name: "mygem", version: "1.0.0", source: git_source)

      downloader = FakeDownloader.new(->(_items) { flunk("should not download .gem for git source") })
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 1, result[:warmed], "git gem should be warmed"
      assert_equal 0, result[:failed], "should have no failures: #{result[:failures].map { |f| f[:error].message }.join(", ")}"
      assert_equal 0, result[:ignored], "git gem should not be ignored"
      assert Dir.exist?(cache.cached_path(spec)), "cached dir should exist"
      assert File.exist?(cache.cached_manifest_path(spec)), "manifest should exist"
    end
  end

  def test_run_skips_git_spec_when_cached_valid
    with_tmpdir do |dir|
      # Create a real git repo
      repo_dir = File.join(dir, "mygem-repo")
      FileUtils.mkdir_p(repo_dir)
      File.write(File.join(repo_dir, "mygem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.version = "1.0.0"
          s.summary = "test"
          s.authors = ["test"]
          s.files = ["lib/mygem.rb"]
          s.require_paths = ["lib"]
        end
      RUBY
      FileUtils.mkdir_p(File.join(repo_dir, "lib"))
      File.write(File.join(repo_dir, "lib", "mygem.rb"), "module Mygem; end\n")
      system("git", "-C", repo_dir, "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "init", out: File::NULL, err: File::NULL)
      revision = `git -C #{repo_dir} rev-parse HEAD`.strip

      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      git_source = Scint::Source::Git.new(uri: repo_dir, revision: revision)
      spec = fake_spec(name: "mygem", version: "1.0.0", source: git_source)

      # Pre-populate cached artifacts so it looks valid
      cached_dir = cache.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached_dir, "lib"))
      File.write(File.join(cached_dir, "lib", "mygem.rb"), "module Mygem; end\n")

      gemspec = Gem::Specification.new do |s|
        s.name = "mygem"
        s.version = Gem::Version.new("1.0.0")
        s.summary = "test"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.cached_spec_path(spec)))
      File.binwrite(cache.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached_dir,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "git", "uri" => repo_dir, "revision" => revision },
        extensions: false,
      )
      Scint::Cache::Manifest.write(cache.cached_manifest_path(spec), manifest)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { flunk("should not download") },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:skipped], "already-cached git gem should be skipped"
      assert_equal 0, result[:failed]
    end
  end

  def test_run_handles_mixed_rubygems_and_git_specs
    with_tmpdir do |dir|
      # Git repo
      repo_dir = File.join(dir, "gitgem-repo")
      FileUtils.mkdir_p(repo_dir)
      File.write(File.join(repo_dir, "gitgem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "gitgem"
          s.version = "0.1.0"
          s.summary = "test"
          s.authors = ["test"]
          s.files = ["lib/gitgem.rb"]
          s.require_paths = ["lib"]
        end
      RUBY
      FileUtils.mkdir_p(File.join(repo_dir, "lib"))
      File.write(File.join(repo_dir, "lib", "gitgem.rb"), "module Gitgem; end\n")
      system("git", "-C", repo_dir, "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "init", out: File::NULL, err: File::NULL)
      revision = `git -C #{repo_dir} rev-parse HEAD`.strip

      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))

      # Rubygems spec
      gem_spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")
      # Git spec
      git_source = Scint::Source::Git.new(uri: repo_dir, revision: revision)
      git_spec = fake_spec(name: "gitgem", version: "0.1.0", source: git_source)
      # Path spec (should be ignored)
      path_spec = fake_spec(name: "localonly", version: "1.0.0", source: "/tmp/localonly")

      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          create_fake_gem(item[:dest], name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 2,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([gem_spec, git_spec, path_spec])

      assert_equal 2, result[:warmed], "both rubygems and git gems should be warmed"
      assert_equal 1, result[:ignored], "path gem should be ignored"
      assert_equal 0, result[:failed], "no failures expected: #{result[:failures].map { |f| "#{f[:spec].name}: #{f[:error].message}" }.join(", ")}"
      assert Dir.exist?(cache.cached_path(gem_spec)), "rubygems cached dir should exist"
      assert Dir.exist?(cache.cached_path(git_spec)), "git cached dir should exist"
    end
  end

  def test_git_manifest_has_correct_source_type
    with_tmpdir do |dir|
      repo_dir = File.join(dir, "mygem-repo")
      FileUtils.mkdir_p(repo_dir)
      File.write(File.join(repo_dir, "mygem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.version = "1.0.0"
          s.summary = "test"
          s.authors = ["test"]
          s.files = ["lib/mygem.rb"]
          s.require_paths = ["lib"]
        end
      RUBY
      FileUtils.mkdir_p(File.join(repo_dir, "lib"))
      File.write(File.join(repo_dir, "lib", "mygem.rb"), "module Mygem; end\n")
      system("git", "-C", repo_dir, "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", repo_dir, "-c", "user.name=test", "-c", "user.email=t@t", "commit", "-m", "init", out: File::NULL, err: File::NULL)
      revision = `git -C #{repo_dir} rev-parse HEAD`.strip

      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      git_source = Scint::Source::Git.new(uri: repo_dir, revision: revision)
      spec = fake_spec(name: "mygem", version: "1.0.0", source: git_source)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { FakeDownloader.new(->(_) { [] }) },
      )
      prewarm.run([spec])

      manifest_path = cache.cached_manifest_path(spec)
      assert File.exist?(manifest_path), "manifest should exist"
      manifest = JSON.parse(File.read(manifest_path))
      assert_equal "git", manifest["source"]["type"]
      assert_equal repo_dir, manifest["source"]["uri"]
      assert_equal revision, manifest["source"]["revision"]
    end
  end
end
