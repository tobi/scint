# frozen_string_literal: true

require_relative "../runtime/exec"

module Bundler2
  module CLI
    class Exec
      RUNTIME_LOCK = "bundler2.lock.marshal"

      def initialize(argv = [])
        @argv = argv
      end

      def run
        if @argv.empty?
          $stderr.puts "bundle2 exec requires a command to run"
          return 1
        end

        command = @argv.first
        args = @argv[1..] || []

        lock_path = find_lock_path
        unless lock_path
          $stderr.puts "No runtime lock found. Run `bundle2 install` first."
          return 1
        end

        # This calls Kernel.exec and never returns on success
        Runtime::Exec.exec(command, args, lock_path)
      end

      private

      def find_lock_path
        # Walk up from cwd looking for .bundle/bundler2.lock.marshal
        dir = Dir.pwd
        loop do
          candidate = File.join(dir, ".bundle", RUNTIME_LOCK)
          return candidate if File.exist?(candidate)

          parent = File.dirname(dir)
          break if parent == dir # reached root
          dir = parent
        end

        nil
      end
    end
  end
end
