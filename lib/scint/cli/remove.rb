# frozen_string_literal: true

require_relative "../errors"
require_relative "../gemfile/editor"
require_relative "install"

module Scint
  module CLI
    class Remove
      def initialize(argv = [])
        @argv = argv.dup
        @skip_install = false
        parse_options
      end

      def run
        if @gems.empty?
          $stderr.puts "Usage: scint remove GEM [GEM...] [--skip-install]"
          return 1
        end

        editor = Gemfile::Editor.new("Gemfile")

        @gems.each do |gem_name|
          if editor.remove(gem_name)
            $stdout.puts "Removed #{gem_name} from Gemfile"
          else
            $stdout.puts "No Gemfile entry found for #{gem_name}"
          end
        end

        return 0 if @skip_install

        CLI::Install.new([]).run
      end

      private

      def parse_options
        @gems = []
        i = 0
        while i < @argv.length
          token = @argv[i]

          case token
          when "--skip-install"
            @skip_install = true
            i += 1
          else
            if token.start_with?("-")
              raise GemfileError, "Unknown option for remove: #{token}"
            end
            @gems << token
            i += 1
          end
        end
      end
    end
  end
end
