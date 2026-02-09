# frozen_string_literal: true

require "net/http"
require "uri"
require "zlib"
require_relative "cache"
require_relative "parser"

module Scint
  module Index
    # Compact index client for rubygems.org (or any compact index source).
    # Thread-safe. Uses ETag/Range for efficient updates.
    class Client
      ACCEPT_ENCODING = "gzip"
      USER_AGENT = "scint/#{Scint::VERSION}"
      DEFAULT_TIMEOUT = 15

      attr_reader :source_uri

      def initialize(source_uri, cache_dir: nil, credentials: nil)
        @source_uri = source_uri.to_s.chomp("/")
        @uri = URI.parse(@source_uri)
        @cache = Cache.new(cache_dir || default_cache_dir)
        @parser = Parser.new
        @credentials = credentials
        @mutex = Thread::Mutex.new
        @fetched = {}  # track which endpoints we've already fetched this session
        @connections = Thread::Queue.new
      end

      # Fetch the list of all gem names from this source.
      def fetch_names
        data = fetch_endpoint("names")
        @parser.parse_names(data)
      end

      # Fetch the versions list. Returns { name => [[name, version, platform], ...] }
      # Also populates info checksums for cache validation.
      def fetch_versions
        data = fetch_endpoint("versions")
        @parser.parse_versions(data)
      end

      # Fetch info for a single gem. Returns parsed info entries.
      # Uses binary cache when checksum matches.
      def fetch_info(gem_name)
        checksums = @parser.info_checksums
        checksum = checksums[gem_name]

        # Try binary cache first
        if checksum && !checksum.empty?
          cached = @cache.read_binary_info(gem_name, checksum)
          return cached if cached
        end

        # Check if local info file matches remote checksum
        if checksum && !checksum.empty? && @cache.info_fresh?(gem_name, checksum)
          data = @cache.info(gem_name)
        else
          data = fetch_info_endpoint(gem_name)
        end

        return [] unless data

        result = @parser.parse_info(gem_name, data)

        # Write binary cache
        if checksum && !checksum.empty? && !result.empty?
          @cache.write_binary_info(gem_name, checksum, result)
        end

        result
      end

      # Prefetch info for multiple gems concurrently.
      # Uses a thread pool for parallel HTTP requests.
      def prefetch(gem_names, worker_count: nil)
        names = Array(gem_names).uniq
        return if names.empty?

        # Ensure versions are fetched first (populates checksums)
        fetch_versions unless @parser.info_checksums.any?

        # Filter to names that actually need fetching
        checksums = @parser.info_checksums
        to_fetch = names.select do |name|
          checksum = checksums[name]
          if checksum && !checksum.empty?
            cached = @cache.read_binary_info(name, checksum)
            !cached
          else
            true
          end
        end.reject do |name|
          checksum = checksums[name]
          checksum && !checksum.empty? && @cache.info_fresh?(name, checksum)
        end

        return if to_fetch.empty?

        pool_size = worker_count || [to_fetch.size, 8].min
        results = {}
        queue = Thread::Queue.new
        to_fetch.each { |n| queue.push(n) }
        pool_size.times { queue.push(:done) }

        threads = pool_size.times.map do
          Thread.new do
            while (name = queue.pop) != :done
              begin
                data = fetch_info_endpoint(name)
                if data
                  parsed = @parser.parse_info(name, data)
                  checksum = checksums[name]
                  if checksum && !checksum.empty? && !parsed.empty?
                    @cache.write_binary_info(name, checksum, parsed)
                  end
                  @mutex.synchronize { results[name] = parsed }
                end
              rescue StandardError => e
                $stderr.puts "prefetch warning: #{name}: #{e.message}" if ENV["SCINT_DEBUG"]
              end
            end
          end
        end

        threads.each(&:join)
        results
      end

      # Shut down any pooled connections.
      def close
        while !@connections.empty?
          begin
            conn = @connections.pop(true)
            conn.finish if conn.started?
          rescue StandardError
            # ignore
          end
        end
      end

      private

      def default_cache_dir
        root =
          if Scint.respond_to?(:cache_root)
            Scint.cache_root
          else
            explicit = ENV["SCINT_CACHE"]
            if explicit && !explicit.empty?
              File.expand_path(explicit)
            else
              xdg = ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache")
              File.join(xdg, "scint")
            end
          end
        File.join(root, "index", Cache.slug_for(@uri))
      end

      # Fetch a top-level endpoint (names or versions).
      # Uses ETag for conditional requests and Range for incremental versions updates.
      def fetch_endpoint(endpoint)
        @mutex.synchronize do
          return @fetched[endpoint] if @fetched.key?(endpoint)
        end

        if endpoint == "versions"
          data = fetch_versions_with_range
        else
          etag = @cache.names_etag
          response = http_get("#{@source_uri}/#{endpoint}", etag: etag)

          case response
          when Net::HTTPNotModified
            data = @cache.names
          when Net::HTTPSuccess
            data = decode_body(response)
            @cache.write_names(data, etag: extract_etag(response))
          else
            raise NetworkError, "Failed to fetch #{endpoint}: HTTP #{response.code}"
          end
        end

        @mutex.synchronize { @fetched[endpoint] = data }
        data
      end

      def fetch_versions_with_range
        etag = @cache.versions_etag
        local_size = @cache.versions_size

        if local_size > 0
          # Try range request (subtract 1 byte for overlap)
          response = http_get("#{@source_uri}/versions", etag: etag, range_start: local_size - 1)

          case response
          when Net::HTTPNotModified
            return @cache.versions
          when Net::HTTPPartialContent
            body = decode_body(response)
            # Skip the overlapping byte
            tail = body.byteslice(1..)
            if tail && !tail.empty?
              @cache.write_versions(tail, etag: extract_etag(response), append: true)
            end
            return @cache.versions
          when Net::HTTPSuccess
            # Server ignored range, gave us full response
            data = decode_body(response)
            @cache.write_versions(data, etag: extract_etag(response))
            return data
          when Net::HTTPRequestedRangeNotSatisfiable
            # Fall through to full fetch
          else
            raise NetworkError, "Failed to fetch versions (range): HTTP #{response.code}"
          end
        end

        # Full fetch
        response = http_get("#{@source_uri}/versions", etag: etag)
        case response
        when Net::HTTPNotModified
          @cache.versions
        when Net::HTTPSuccess
          data = decode_body(response)
          @cache.write_versions(data, etag: extract_etag(response))
          data
        else
          raise NetworkError, "Failed to fetch versions: HTTP #{response.code}"
        end
      end

      # Fetch info endpoint for a single gem.
      def fetch_info_endpoint(gem_name)
        etag = @cache.info_etag(gem_name)
        response = http_get("#{@source_uri}/info/#{gem_name}", etag: etag)

        case response
        when Net::HTTPNotModified
          @cache.info(gem_name)
        when Net::HTTPSuccess
          data = decode_body(response)
          @cache.write_info(gem_name, data, etag: extract_etag(response))
          data
        when Net::HTTPNotFound
          nil
        else
          raise NetworkError, "Failed to fetch info/#{gem_name}: HTTP #{response.code}"
        end
      end

      def http_get(url, etag: nil, range_start: nil)
        uri = URI.parse(url)
        conn = checkout_connection(uri)

        begin
          request = Net::HTTP::Get.new(uri.request_uri)
          request["User-Agent"] = USER_AGENT
          request["Accept-Encoding"] = ACCEPT_ENCODING
          request["If-None-Match"] = %("#{etag}") if etag
          request["Range"] = "bytes=#{range_start}-" if range_start
          @credentials&.apply!(request, uri)

          conn.request(request)
        ensure
          checkin_connection(conn)
        end
      end

      def checkout_connection(uri)
        begin
          conn = @connections.pop(true)
          return conn if conn.started?
        rescue ThreadError
          # Queue empty
        end

        conn = Net::HTTP.new(uri.host, uri.port)
        conn.use_ssl = (uri.scheme == "https")
        conn.open_timeout = DEFAULT_TIMEOUT
        conn.read_timeout = DEFAULT_TIMEOUT
        conn.start
        conn
      end

      def checkin_connection(conn)
        @connections.push(conn) if conn.started?
      rescue StandardError
        # ignore
      end

      def decode_body(response)
        body = response.body
        return body unless body

        if response["Content-Encoding"] == "gzip"
          Zlib::GzipReader.new(StringIO.new(body)).read
        else
          body
        end
      end

      def extract_etag(response)
        return nil unless response["ETag"]
        etag = response["ETag"].delete_prefix("W/")
        etag = etag.delete_prefix('"').delete_suffix('"')
        etag.empty? ? nil : etag
      end
    end
  end
end
