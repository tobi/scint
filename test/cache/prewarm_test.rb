# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/prewarm"
require "scint/cache/layout"

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
      assert Dir.exist?(cache.extracted_path(spec))
      assert File.exist?(cache.spec_cache_path(spec))
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
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "x"), "x")
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.write(cache.spec_cache_path(spec), "---\n")

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
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "old"), "old")
      meta = cache.spec_cache_path(spec)
      FileUtils.mkdir_p(File.dirname(meta))
      File.write(meta, "old-spec")

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
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

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

  def test_extract_false_but_metadata_missing_reads_metadata
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      # Pre-populate inbound and extracted dir, but leave metadata missing
      # This means task.download=false, task.extract is based on
      # !Dir.exist?(extracted) || !File.exist?(metadata)
      # We want: extracted exists, metadata does NOT exist => extract=true
      # BUT to hit lines 142-143 specifically, we need task.extract=false
      # and !File.exist?(metadata). That means extracted dir exists AND metadata
      # exists for task_for to set extract=false, then we remove metadata before extraction.
      #
      # Actually re-reading: task_for sets extract = !Dir.exist?(extracted) || !File.exist?(metadata)
      # If extracted exists but metadata doesn't => extract=true, which runs lines 137-141.
      # Lines 142-143 are: elsif !File.exist?(metadata) -- this is reached when
      # task.extract is true BUT the inner `if task.extract` (line 137) is false.
      # Wait, task.extract is a Struct field set by task_for. Let's re-read:
      #
      # Line 137: if task.extract  (this runs lines 138-141)
      # Line 142: elsif !File.exist?(metadata)  (this is the else-branch)
      #
      # For lines 142-143 to execute, task.extract must be falsy but metadata must not exist.
      # task_for sets extract = !Dir.exist?(extracted) || !File.exist?(metadata)
      # So if extracted exists AND metadata exists => extract=false, download depends on inbound.
      # But then at line 142, !File.exist?(metadata) would be false, so 142-143 wouldn't run.
      #
      # The only way to reach 142-143: task.extract was set to false externally
      # OR the metadata was removed between task_for and extract_tasks.
      # Actually, looking more carefully: the field is a Struct field. Maybe
      # force mode modifies it? No, force sets both to true.
      #
      # Actually wait -- re-reading: task.extract could be false if both
      # Dir.exist?(extracted) AND File.exist?(metadata). Then during extraction,
      # the task would not be in the work_tasks at all (line 58 filters it out).
      # So lines 142-143 can only run if extract=true but the inner `if task.extract`
      # ... wait, that IS the same field. If task.extract is true, line 137 runs.
      # If task.extract is false, line 142 checks metadata.
      #
      # For task to be in extract_tasks (line 68), task.extract must be true.
      # But if task.extract is true, line 137 is true, so lines 142-143 never run?
      #
      # Hmm, let me re-read the flow more carefully...
      # Line 68: extract_errors = extract_tasks(remaining.select(&:extract))
      # So all tasks passed to extract_tasks have extract=true.
      # Inside the worker (line 137): if task.extract => always true.
      # So lines 142-143 are dead code within the current flow? Unless task.extract
      # is modified elsewhere.
      #
      # Actually no! The extract field could have been set to false in task_for
      # but the task still has download=true. After downloading, line 64-66
      # filters out failures. Line 68: remaining.select(&:extract) -- if extract
      # is false, the task won't be selected for extraction. So lines 142-143
      # would never be reached through the normal flow.
      #
      # BUT: we can construct a scenario where we directly call extract_tasks
      # with a task that has extract=false but is in the list. Or we can modify
      # the task struct. Let's test it by creating a scenario where the task's
      # extract field is manipulated.
      #
      # Actually, the simplest approach: the Prewarm class uses a WorkerPool,
      # and the worker block (line 125-151) receives any task. We can test the
      # prewarm worker block by creating a task with extract=false and metadata missing.
      # The cleanest approach: create the right initial conditions.
      #
      # Let me think again about task_for:
      # download: !File.exist?(inbound) -- false if inbound exists
      # extract: !Dir.exist?(extracted) || !File.exist?(metadata) -- could be true
      #
      # For work_tasks (line 58): task.download || task.extract
      # For extract_tasks (line 68): remaining.select(&:extract)
      #
      # So if download=false and extract=true, the task goes to extract_tasks with extract=true.
      # Then line 137 `if task.extract` is true, so lines 138-141 run, NOT 142-143.
      #
      # The only way 142-143 run is if task.extract is falsy when the worker processes it.
      # Could happen if force changes it? Let's see force code (lines 44-50):
      # force sets download=true and extract=true. That doesn't help.
      #
      # So lines 142-143 appear unreachable through the public API. But the user
      # asked us to test them. We can test the worker block directly by calling
      # extract_tasks with a crafted task where extract=false.

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      # Do NOT create metadata file

      # Create prewarm and directly call extract_tasks with a task where extract=false
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { flunk("should not download") },
      )

      task = Scint::Cache::Prewarm::Task.new(spec: spec, download: false, extract: false)
      # Call the private extract_tasks with our crafted task
      failures = prewarm.send(:extract_tasks, [task])

      assert_empty failures
      # Metadata should now exist (read_metadata was called, lines 142-143)
      assert File.exist?(cache.spec_cache_path(spec)), "metadata file should have been written via read_metadata path"
    end
  end
end
