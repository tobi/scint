# frozen_string_literal: true

module Scint
  module CLI
    COMMANDS = %w[install add remove exec cache version help].freeze

    def self.run(argv)
      argv = argv.dup
      command = argv.shift || "install"

      case command
      when "install", "i"
        require_relative "cli/install"
        CLI::Install.new(argv).run
      when "add"
        require_relative "cli/add"
        CLI::Add.new(argv).run
      when "remove", "rm"
        require_relative "cli/remove"
        CLI::Remove.new(argv).run
      when "exec", "e"
        require_relative "cli/exec"
        CLI::Exec.new(argv).run
      when "cache", "c"
        require_relative "cli/cache"
        CLI::Cache.new(argv).run
      when "version", "-v", "--version"
        $stdout.puts "scint #{Scint::VERSION}"
        0
      when "help", "-h", "--help"
        print_help
        0
      else
        $stderr.puts "Unknown command: #{command}"
        $stderr.puts "Run 'scint help' for usage."
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
        Usage: scint COMMAND [OPTIONS]

        Commands:
          install    Install gems from Gemfile (default)
          add        Add gem(s) to Gemfile and install
          remove     Remove gem(s) from Gemfile and install
          exec       Execute a command in the bundle context
          cache      Manage scint cache (list/clear/dir)
          version    Print version
          help       Show this help

        Options:
          --jobs N   Number of parallel workers (default: auto)
          --path P   Install gems to path
          --verbose  Verbose output
          --force    Reinstall all gems, ignoring cache and local bundle state
      HELP
    end
  end
end
