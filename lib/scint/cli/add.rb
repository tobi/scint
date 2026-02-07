# frozen_string_literal: true

require_relative "../errors"
require_relative "../gemfile/editor"
require_relative "install"

module Scint
  module CLI
    class Add
      def initialize(argv = [])
        @argv = argv.dup
        @skip_install = false
        @requirement = nil
        @group = nil
        @source = nil
        @git = nil
        @path = nil
        parse_options
      end

      def run
        if @gems.empty?
          $stderr.puts "Usage: scint add GEM [GEM...] [options]"
          return 1
        end

        editor = Gemfile::Editor.new("Gemfile")
        @gems.each do |gem_name|
          result = editor.add(
            gem_name,
            requirement: @requirement,
            group: @group,
            source: @source,
            git: @git,
            path: @path,
          )

          action = result == :updated ? "Updated" : "Added"
          $stdout.puts "#{action} #{gem_name} in Gemfile"
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
          when "--version"
            @requirement = @argv[i + 1]
            i += 2
          when "--group"
            @group = @argv[i + 1]
            i += 2
          when "--source"
            @source = @argv[i + 1]
            i += 2
          when "--git"
            @git = @argv[i + 1]
            i += 2
          when "--path"
            @path = @argv[i + 1]
            i += 2
          else
            if token.start_with?("-")
              raise GemfileError, "Unknown option for add: #{token}"
            end
            @gems << token
            i += 1
          end
        end
      end
    end
  end
end
