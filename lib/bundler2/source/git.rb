# frozen_string_literal: true

require_relative "base"
require "digest/sha2"

module Bundler2
  module Source
    class Git < Base
      attr_reader :uri, :revision, :ref, :branch, :tag, :submodules, :glob

      DEFAULT_GLOB = "{,*,*/*}.gemspec"

      def initialize(uri:, revision: nil, ref: nil, branch: nil, tag: nil,
                     submodules: nil, glob: nil, name: nil)
        @uri = uri.to_s
        @revision = revision
        @ref = ref || branch || tag
        @branch = branch
        @tag = tag
        @submodules = submodules
        @glob = glob || DEFAULT_GLOB
        @name = name
      end

      def self.from_lock(options)
        new(
          uri: options.delete("remote"),
          revision: options["revision"],
          ref: options["ref"],
          branch: options["branch"],
          tag: options["tag"],
          submodules: options["submodules"],
          glob: options["glob"],
          name: options["name"],
        )
      end

      def name
        @name || File.basename(uri, ".git")
      end

      def specs
        [] # Loaded from checked-out gemspec at resolution time
      end

      def fetch_spec(name, version, platform = "ruby")
        nil
      end

      def cache_slug
        "#{name}-#{uri_hash}"
      end

      def to_lock
        out = String.new("GIT\n")
        out << "  remote: #{@uri}\n"
        out << "  revision: #{@revision}\n" if @revision
        out << "  ref: #{@ref}\n" if @ref && @ref != @branch && @ref != @tag
        out << "  branch: #{@branch}\n" if @branch
        out << "  tag: #{@tag}\n" if @tag
        out << "  submodules: #{@submodules}\n" if @submodules
        out << "  glob: #{@glob}\n" unless @glob == DEFAULT_GLOB
        out << "  specs:\n"
        out
      end

      def eql?(other)
        other.is_a?(Git) &&
          uri == other.uri &&
          ref == other.ref &&
          branch == other.branch &&
          tag == other.tag &&
          submodules == other.submodules
      end

      def hash
        [self.class, uri, ref, branch, tag, submodules].hash
      end

      def to_s
        at = tag || branch || ref
        "git: #{@uri}#{" (#{at})" if at}"
      end

      private

      def uri_hash
        Digest::SHA256.hexdigest(@uri)[0, 12]
      end
    end
  end
end
