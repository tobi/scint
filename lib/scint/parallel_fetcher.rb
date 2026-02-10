# frozen_string_literal: true

require_relative "downloader/pool"
require_relative "worker_pool"
require_relative "fs"
require "uri"

module Scint
  # Parallel gem fetcher. Downloads .gem files from rubygems.org (or custom
  # sources) with connection pooling, per-host rate limiting, and retries.
  #
  # Usage:
  #   fetcher = Scint::ParallelFetcher.new(concurrency: 20, dest_dir: "cache/gems")
  #   results = fetcher.fetch_gems(items) { |result| ... }
  #   fetcher.close
  #
  # Each item: { name:, version:, source_uri: "https://rubygems.org/" }
  # Results:   { name:, version:, path:, error: }
  #
  class ParallelFetcher
    DEFAULT_CONCURRENCY = 20

    def initialize(concurrency: DEFAULT_CONCURRENCY, dest_dir:, credentials: nil)
      @concurrency = concurrency
      @dest_dir = dest_dir
      @pool = Downloader::Pool.new(size: concurrency, credentials: credentials)
    end

    # Fetch a batch of gems in parallel.
    # items: [{ name:, version:, source_uri: }]
    # Yields each result as it completes (thread-safe).
    # Returns array of all results.
    def fetch_gems(items, &on_complete)
      results = []
      mutex = Mutex.new

      worker = WorkerPool.new(@concurrency, name: "gem-fetch")
      remaining = items.size
      done = Thread::Queue.new

      worker.start do |item|
        result = fetch_one(item)
        mutex.synchronize { results << result }
        on_complete&.call(result)
        done.push(true)
        result
      end

      items.each { |item| worker.enqueue(item) }
      remaining.times { done.pop }
      worker.stop

      results
    end

    def close
      @pool.close
    end

    private

    def fetch_one(item)
      name = item[:name]
      version = item[:version]
      source_uri = item[:source_uri] || "https://rubygems.org/"

      dest_path = File.join(@dest_dir, "#{name}-#{version}.gem")

      # Already downloaded?
      if File.exist?(dest_path) && File.size(dest_path) > 0
        return { name: name, version: version, path: dest_path, error: nil, cached: true }
      end

      FS.mkdir_p(@dest_dir)

      # Try platform-agnostic first, then any platform
      uri = gem_uri(source_uri, name, version)
      result = @pool.download(uri, dest_path)
      { name: name, version: version, path: result[:path], error: nil, cached: false }

    rescue => e
      { name: name, version: version, path: nil, error: e, cached: false }
    end

    def gem_uri(source_uri, name, version)
      base = source_uri.chomp("/")
      "#{base}/gems/#{name}-#{version}.gem"
    end
  end
end
