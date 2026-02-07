# frozen_string_literal: true

require_relative "base"
require "uri"

module Scint
  module Source
    class Rubygems < Base
      attr_reader :remotes

      def initialize(remotes: [])
        @remotes = Array(remotes).map { |r| normalize_uri(r) }
      end

      def self.from_lock(options)
        remotes = Array(options["remote"]).reverse
        new(remotes: remotes)
      end

      def name
        "rubygems"
      end

      def uri
        @remotes.first
      end

      def add_remote(remote)
        remote = normalize_uri(remote)
        @remotes << remote unless @remotes.include?(remote)
      end

      def specs
        [] # Populated by compact index client at resolution time
      end

      def fetch_spec(name, version, platform = "ruby")
        nil # Delegated to compact index / API at resolution time
      end

      def cache_slug
        uri_obj = URI.parse(@remotes.first.to_s)
        path = uri_obj.path.gsub("/", "-").sub(/^-/, "")
        slug = uri_obj.host.to_s
        slug += path unless path.empty? || path == "-"
        slug
      end

      def to_lock
        out = String.new("GEM\n")
        @remotes.reverse_each do |remote|
          out << "  remote: #{remote}\n"
        end
        out << "  specs:\n"
        out
      end

      def eql?(other)
        other.is_a?(Rubygems) && @remotes == other.remotes
      end

      def hash
        [self.class, @remotes].hash
      end

      def to_s
        "rubygems (#{@remotes.join(", ")})"
      end

      private

      def normalize_uri(uri)
        uri = uri.to_s
        uri = "#{uri}/" unless uri.end_with?("/")
        uri
      end
    end
  end
end
