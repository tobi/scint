# frozen_string_literal: true

require_relative "../cli/install"

module Bundler2
  module Commands
    class Install
      def initialize(argv)
        @impl = CLI::Install.new(argv)
      end

      def run
        @impl.run
      end
    end
  end
end
