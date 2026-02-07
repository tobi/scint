# frozen_string_literal: true

require_relative "../cli/exec"

module Scint
  module Commands
    class Exec
      def initialize(argv)
        @impl = CLI::Exec.new(argv)
      end

      def run
        @impl.run
      end
    end
  end
end
