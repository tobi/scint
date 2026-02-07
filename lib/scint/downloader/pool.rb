# frozen_string_literal: true

require_relative "fetcher"
require_relative "../worker_pool"
require_relative "../platform"
require_relative "../errors"
require "uri"

module Scint
  module Downloader
    class Pool
      MAX_RETRIES = 3
      BACKOFF_BASE = 0.5 # seconds
      DEFAULT_PER_HOST_LIMIT = 4

      attr_reader :size

      def initialize(size: nil, on_progress: nil, credentials: nil, per_host_limit: DEFAULT_PER_HOST_LIMIT)
        @size = size || [Platform.cpu_count * 2, 50].min
        @on_progress = on_progress
        @credentials = credentials
        @per_host_limit = [per_host_limit.to_i, 1].max
        @fetchers = {} # thread_id => Fetcher
        @fetcher_mutex = Thread::Mutex.new
        @host_slots = Hash.new(0)
        @host_waiters = {}
        @host_mutex = Thread::Mutex.new
      end

      # Download a single URI to dest_path with retry logic.
      # Returns { path:, size: }
      def download(uri, dest_path, checksum: nil)
        with_host_slot(uri) do
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

      def with_host_slot(uri)
        key = host_slot_key(uri)
        return yield unless key

        waiter = nil
        @host_mutex.synchronize do
          waiter = (@host_waiters[key] ||= Thread::ConditionVariable.new)
          while @host_slots[key] >= @per_host_limit
            waiter.wait(@host_mutex)
          end
          @host_slots[key] += 1
        end

        begin
          yield
        ensure
          @host_mutex.synchronize do
            @host_slots[key] -= 1 if @host_slots[key] > 0
            waiter.broadcast
          end
        end
      end

      def host_slot_key(uri)
        parsed = uri.is_a?(URI) ? uri : URI.parse(uri.to_s)
        return nil unless parsed.host

        scheme = parsed.scheme || "https"
        port = parsed.port || (scheme == "https" ? 443 : 80)
        "#{scheme}://#{parsed.host}:#{port}"
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
