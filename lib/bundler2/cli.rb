# frozen_string_literal: true

module Bundler2
  module CLI
    COMMANDS = %w[install exec cache version help].freeze

    def self.run(argv)
      argv = argv.dup
      command = argv.shift || "install"

      case command
      when "install", "i"
        require_relative "cli/install"
        CLI::Install.new(argv).run
      when "exec", "e"
        require_relative "cli/exec"
        CLI::Exec.new(argv).run
      when "cache", "c"
        require_relative "cli/cache"
        CLI::Cache.new(argv).run
      when "version", "-v", "--version"
        $stdout.puts "bundler2 #{Bundler2::VERSION}"
        0
      when "help", "-h", "--help"
        print_help
        0
      else
        $stderr.puts "Unknown command: #{command}"
        $stderr.puts "Run 'bundle2 help' for usage."
        1
      end
    rescue BundlerError => e
      $stderr.puts "Error: #{e.message}"
      e.status_code
    rescue Interrupt
      $stderr.puts "\nInterrupted"
      130
    rescue => e
      $stderr.puts "Fatal: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.first(10).map { |l| "  #{l}" }.join("\n")
      1
    end

    def self.print_help
      $stdout.puts <<~HELP
        Usage: bundle2 COMMAND [OPTIONS]

        Commands:
          install    Install gems from Gemfile (default)
          exec       Execute a command in the bundle context
          cache      Manage bundler2 cache (list/clear/dir)
          version    Print version
          help       Show this help

        Options:
          --jobs N   Number of parallel workers (default: auto)
          --path P   Install gems to path
          --verbose  Verbose output
      HELP
    end
  end
end
