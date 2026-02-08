# frozen_string_literal: true

require "fileutils"
require_relative "layout"
require_relative "manifest"
require_relative "validity"
require_relative "../errors"
require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../fs"
require_relative "../platform"
require_relative "../worker_pool"
require_relative "../installer/extension_builder"
require_relative "../installer/promoter"

module Scint
  module Cache
    class Prewarm
      Task = Struct.new(:spec, :download, :extract, keyword_init: true)

      def initialize(cache_layout: Layout.new, jobs: nil, credentials: nil, force: false,
                     downloader_factory: nil)
        @cache = cache_layout
        @jobs = [[jobs || (Platform.cpu_count * 2), 1].max, 50].min
        @credentials = credentials
        @force = force
        @downloader_factory = downloader_factory || lambda { |size, creds|
          Downloader::Pool.new(size: size, credentials: creds)
        }
      end

      # Returns summary hash:
      # { warmed:, skipped:, ignored:, failed:, failures: [] }
      def run(specs)
        failures = []
        ignored = 0
        skipped = 0

        tasks = []
        specs.each do |spec|
          if prewarmable?(spec)
            tasks << task_for(spec)
          else
            ignored += 1
          end
        end

        tasks.each do |task|
          next unless @force

          purge_artifacts(task.spec)
          task.download = true
          task.extract = true
        end

        tasks.each do |task|
          if !task.download && !task.extract
            skipped += 1
          end
        end

        work_tasks = tasks.select { |task| task.download || task.extract }
        return result_hash(work_tasks.size, skipped, ignored, failures) if work_tasks.empty?

        download_errors = download_tasks(work_tasks.select(&:download))
        failures.concat(download_errors)

        remaining = work_tasks.reject do |task|
          failures.any? { |f| f[:spec] == task.spec }
        end

        extract_errors = extract_tasks(remaining.select(&:extract))
        failures.concat(extract_errors)

        result_hash(work_tasks.size - failures.size, skipped, ignored, failures)
      end

      private

      def task_for(spec)
        inbound = @cache.inbound_path(spec)
        cached_valid = Cache::Validity.cached_valid?(spec, @cache)

        Task.new(
          spec: spec,
          download: !File.exist?(inbound),
          extract: !cached_valid,
        )
      end

      def prewarmable?(spec)
        source = spec.source
        source_str = source.to_s
        source_str.start_with?("http://", "https://")
      end

      def download_tasks(tasks)
        return [] if tasks.empty?

        downloader = @downloader_factory.call(@jobs, @credentials)
        items = tasks.map do |task|
          spec = task.spec
          {
            spec: spec,
            uri: download_uri_for(spec),
            dest: @cache.inbound_path(spec),
            checksum: spec.respond_to?(:checksum) ? spec.checksum : nil,
          }
        end

        results = downloader.download_batch(items)
        failures = results.select { |r| r[:error] }.map do |r|
          { spec: r[:spec], error: r[:error] }
        end
        failures
      ensure
        downloader&.close
      end

      def extract_tasks(tasks)
        return [] if tasks.empty?

        failures = []
        mutex = Thread::Mutex.new
        done = Thread::Queue.new

        pool = WorkerPool.new(@jobs, name: "prewarm-extract")
        pool.start do |task|
          spec = task.spec
          inbound = @cache.inbound_path(spec)

          unless File.exist?(inbound)
            raise CacheError, "Missing downloaded gem for #{spec.name}: #{inbound}"
          end

          assembling = @cache.assembling_path(spec)
          tmp = "#{assembling}.#{Process.pid}.#{Thread.current.object_id}.tmp"

          gemspec = nil
          if task.extract
            FileUtils.rm_rf(assembling)
            FileUtils.rm_rf(tmp)
            FS.mkdir_p(File.dirname(assembling))

            result = GemPkg::Package.new.extract(inbound, tmp)
            gemspec = result[:gemspec]
            FS.atomic_move(tmp, assembling)
          end

          if gemspec
            promote_assembled(spec, assembling, gemspec)
          end

          true
        ensure
          FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
        end

        tasks.each do |task|
          pool.enqueue(task) do |job|
            mutex.synchronize do
              if job[:state] == :failed
                failures << { spec: job[:payload].spec, error: job[:error] }
              end
            end
            done.push(true)
          end
        end

        tasks.size.times { done.pop }
        pool.stop

        failures
      end

      def promote_assembled(spec, assembling, gemspec)
        return unless assembling && Dir.exist?(assembling)

        cached_dir = @cache.cached_path(spec)
        promoter = Installer::Promoter.new(root: @cache.root)
        lock_key = "#{Platform.abi_key}-#{@cache.full_name(spec)}"
        extensions = Installer::ExtensionBuilder.needs_build?(spec, assembling)

        promoter.with_staging_dir(prefix: "cached") do |staging|
          FS.clone_tree(assembling, staging)
          manifest = Cache::Manifest.build(
            spec: spec,
            gem_dir: staging,
            abi_key: Platform.abi_key,
            source: { "type" => "rubygems", "uri" => spec.source.to_s },
            extensions: extensions,
          )
          spec_payload = gemspec ? Marshal.dump(gemspec) : nil
          result = promoter.promote_tree(
            staging_path: staging,
            target_path: cached_dir,
            lock_key: lock_key,
          )
          write_cached_metadata(spec, spec_payload, manifest) if result == :promoted
        end

        FileUtils.rm_rf(assembling)
      end

      def write_cached_metadata(spec, spec_payload, manifest)
        spec_path = @cache.cached_spec_path(spec)
        manifest_path = @cache.cached_manifest_path(spec)
        FS.mkdir_p(File.dirname(spec_path))

        FS.atomic_write(spec_path, spec_payload) if spec_payload
        Cache::Manifest.write(manifest_path, manifest)
      end

      def download_uri_for(spec)
        source = spec.source.to_s.chomp("/")
        "#{source}/gems/#{@cache.full_name(spec)}.gem"
      end

      def purge_artifacts(spec)
        FileUtils.rm_f(@cache.inbound_path(spec))
        FileUtils.rm_rf(@cache.assembling_path(spec))
        FileUtils.rm_rf(@cache.cached_path(spec))
        FileUtils.rm_f(@cache.cached_spec_path(spec))
        FileUtils.rm_f(@cache.cached_manifest_path(spec))
        FileUtils.rm_f(@cache.spec_cache_path(spec))
        FileUtils.rm_rf(@cache.extracted_path(spec))
        FileUtils.rm_rf(@cache.ext_path(spec))
      end

      def result_hash(warmed, skipped, ignored, failures)
        {
          warmed: warmed,
          skipped: skipped,
          ignored: ignored,
          failed: failures.size,
          failures: failures,
        }
      end
    end
  end
end
