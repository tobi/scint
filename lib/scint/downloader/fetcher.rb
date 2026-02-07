# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require_relative "../fs"
require_relative "../errors"

module Scint
  module Downloader
    class Fetcher
      MAX_REDIRECTS = 5

      def initialize(credentials: nil)
        @connections = {} # "host:port" => Net::HTTP
        @mutex = Thread::Mutex.new
        @credentials = credentials
      end

      # Download a single file from uri to dest_path.
      # Streams to a temp file then atomically renames.
      # Returns { path: dest_path, size: bytes }
      def fetch(uri, dest_path, checksum: nil)
        uri = URI.parse(uri) unless uri.is_a?(URI)
        FS.mkdir_p(File.dirname(dest_path))

        tmp_path = "#{dest_path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        size = 0

        begin
          redirect_count = 0
          current_uri = uri

          loop do
            http = connection_for(current_uri)
            request = Net::HTTP::Get.new(current_uri.request_uri)
            request["Accept-Encoding"] = "identity"
            @credentials&.apply!(request, current_uri)

            response = http.request(request)

            case response
            when Net::HTTPSuccess
              File.open(tmp_path, "wb") do |f|
                body = response.body
                f.write(body)
                size = body.bytesize
              end
              break
            when Net::HTTPRedirection
              redirect_count += 1
              raise NetworkError, "Too many redirects for #{uri}" if redirect_count > MAX_REDIRECTS
              location = response["location"]
              current_uri = URI.parse(location)
              next
            else
              raise NetworkError, "HTTP #{response.code} for #{uri}: #{response.message}"
            end
          end

          if checksum
            actual = Digest::SHA256.file(tmp_path).hexdigest
            unless actual == checksum
              File.delete(tmp_path) if File.exist?(tmp_path)
              raise NetworkError, "Checksum mismatch for #{uri}: expected #{checksum}, got #{actual}"
            end
          end

          File.rename(tmp_path, dest_path)
          { path: dest_path, size: size }
        rescue StandardError
          File.delete(tmp_path) if File.exist?(tmp_path)
          raise
        end
      end

      # Close all persistent connections.
      def close
        @mutex.synchronize do
          @connections.each_value do |http|
            http.finish if http.started?
          rescue StandardError
            # ignore close errors
          end
          @connections.clear
        end
      end

      private

      def connection_for(uri)
        key = "#{uri.host}:#{uri.port}:#{uri.scheme}"

        @mutex.synchronize do
          http = @connections[key]
          if http && http.started?
            return http
          end

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 10
          http.read_timeout = 30
          http.keep_alive_timeout = 30
          http.start

          @connections[key] = http
          http
        end
      end
    end
  end
end
