# frozen_string_literal: true

module Scint
  module Source
    # Abstract base class for all gem sources.
    # Subclasses must implement: #name, #uri, #specs, #fetch_spec,
    # #cache_slug, #to_lock, #eql?, #hash.
    class Base
      def name
        raise NotImplementedError
      end

      def uri
        raise NotImplementedError
      end

      # Return an array of available specs from this source.
      def specs
        raise NotImplementedError
      end

      # Fetch a specific spec by name, version, and platform.
      def fetch_spec(name, version, platform = "ruby")
        raise NotImplementedError
      end

      # A unique slug used for cache directory naming.
      def cache_slug
        raise NotImplementedError
      end

      # Lockfile representation (the header section, e.g. "GEM\n  remote: ...\n  specs:\n")
      def to_lock
        raise NotImplementedError
      end

      def to_s
        "#{self.class.name.split("::").last}: #{uri}"
      end

      def ==(other)
        eql?(other)
      end
    end
  end
end
