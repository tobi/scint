# frozen_string_literal: true

require_relative "fetcher"
require_relative "../worker_pool"
require_relative "../platform"
require_relative "../errors"

module Scint
  module Downloader
    class Pool
      MAX_RETRIES = 3
      BACKOFF_BASE = 0.5 # seconds

      attr_reader :size

      def initialize(size: nil, on_progress: nil, credentials: nil)
        @size = size || [Platform.cpu_count * 2, 50].min
        @on_progress = on_progress
        @credentials = credentials
        @fetchers = {} # thread_id => Fetcher
        @fetcher_mutex = Thread::Mutex.new
      end

      # Download a single URI to dest_path with retry logic.
      # Returns { path:, size: }
      def download(uri, dest_path, checksum: nil)
        retries = 0
        begin
          fetcher = thread_fetcher
          fetcher.fetch(uri, dest_path, checksum: checksum)
        rescue NetworkError, Errno::ECONNRESET, Errno::ECONNREFUSED,
               Errno::ETIMEDOUT, Net::ReadTimeout, Net::OpenTimeout,
               SocketError, IOError => e
          retries += 1
          if retries <= MAX_RETRIES
            sleep(BACKOFF_BASE * (2**(retries - 1)))
            # Reset connection on retry
            reset_thread_fetcher
            retry
          end
          raise NetworkError, "Failed to download #{uri} after #{MAX_RETRIES} retries: #{e.message}"
        end
      end

      # Download multiple items concurrently.
      # items: [{ uri:, dest:, spec:, checksum: }]
      # Returns array of { spec:, path:, size:, error: }
      def download_batch(items)
        results = []
        result_mutex = Thread::Mutex.new

        pool = WorkerPool.new(@size, name: "download")
        remaining = items.size

        done = Thread::Queue.new

        pool.start do |item|
          result = download_one(item)
          result_mutex.synchronize { results << result }
          @on_progress&.call(result)
          done.push(true)
          result
        end

        items.each { |item| pool.enqueue(item) }

        remaining.times { done.pop }
        pool.stop

        results
      end

      # Close all connections across all threads.
      def close
        @fetcher_mutex.synchronize do
          @fetchers.each_value(&:close)
          @fetchers.clear
        end
      end

      private

      def download_one(item)
        uri = item[:uri]
        dest = item[:dest]
        spec = item[:spec]
        checksum = item[:checksum]

        result = download(uri, dest, checksum: checksum)
        { spec: spec, path: result[:path], size: result[:size], error: nil }
      rescue StandardError => e
        { spec: spec, path: nil, size: 0, error: e }
      end

      # Each thread gets its own Fetcher for connection reuse without locking.
      def thread_fetcher
        tid = Thread.current.object_id
        @fetcher_mutex.synchronize do
          @fetchers[tid] ||= Fetcher.new(credentials: @credentials)
        end
      end

      def reset_thread_fetcher
        tid = Thread.current.object_id
        @fetcher_mutex.synchronize do
          old = @fetchers.delete(tid)
          old&.close
        end
      end
    end
  end
end
