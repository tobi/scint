# frozen_string_literal: true

module Scint
  module Gemfile
    # Represents a single gem dependency declared in a Gemfile.
    # This is an intermediate type used during Gemfile parsing;
    # the resolver and installer use the top-level Scint::Dependency struct.
    class Dependency
      attr_reader :name, :version_reqs, :groups, :platforms, :require_paths, :source_options

      def initialize(name, version_reqs: [], groups: [:default], platforms: [],
                     require_paths: nil, source_options: {})
        @name = name.to_s.freeze
        @version_reqs = version_reqs.empty? ? [">= 0"] : version_reqs
        @groups = groups.map(&:to_sym)
        @platforms = platforms.map(&:to_sym)
        @require_paths = require_paths
        @source_options = source_options
      end

      def to_s
        if version_reqs == [">= 0"]
          name
        else
          "#{name} (#{version_reqs.join(", ")})"
        end
      end
    end
  end
end
