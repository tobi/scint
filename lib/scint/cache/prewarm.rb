# frozen_string_literal: true

require "fileutils"
require_relative "layout"
require_relative "../errors"
require_relative "../downloader/pool"
require_relative "../gem/package"
require_relative "../fs"
require_relative "../platform"
require_relative "../worker_pool"

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
        extracted = @cache.extracted_path(spec)
        metadata = @cache.spec_cache_path(spec)

        Task.new(
          spec: spec,
          download: !File.exist?(inbound),
          extract: !Dir.exist?(extracted) || !File.exist?(metadata),
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

          extracted = @cache.extracted_path(spec)
          metadata = @cache.spec_cache_path(spec)

          gemspec = nil
          if task.extract
            FileUtils.rm_rf(extracted)
            FS.mkdir_p(extracted)
            result = GemPkg::Package.new.extract(inbound, extracted)
            gemspec = result[:gemspec]
          elsif !File.exist?(metadata)
            gemspec = GemPkg::Package.new.read_metadata(inbound)
          end

          if gemspec
            FS.atomic_write(metadata, gemspec.to_yaml)
          end

          true
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

      def download_uri_for(spec)
        source = spec.source.to_s.chomp("/")
        "#{source}/gems/#{@cache.full_name(spec)}.gem"
      end

      def purge_artifacts(spec)
        FileUtils.rm_f(@cache.inbound_path(spec))
        FileUtils.rm_rf(@cache.extracted_path(spec))
        FileUtils.rm_f(@cache.spec_cache_path(spec))
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
