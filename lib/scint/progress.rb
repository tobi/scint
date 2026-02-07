# frozen_string_literal: true

module Scint
  class Progress
    PHASE_LABELS = {
      fetch_index: "Fetching index",
      git_clone: "Cloning",
      resolve: "Resolving",
      download: "Downloading",
      extract: "Extracting",
      link: "Linking",
      build_ext: "Building",
    }.freeze

    def initialize(output: $stderr)
      @output = output
      @mutex = Thread::Mutex.new
      @started = 0
      @completed = Hash.new(0)
      @failed = Hash.new(0)
      @total = Hash.new(0)
    end

    def start = nil
    def stop = nil

    def on_enqueue(job_id, type, name)
      @mutex.synchronize { @total[type] += 1 }
    end

    def on_start(job_id, type, name)
      @mutex.synchronize do
        @started += 1
        label = PHASE_LABELS[type] || type.to_s
        @output.puts "#{GREEN}[#{@started}/#{total_jobs}]#{RESET} #{label} #{BOLD}#{name}#{RESET}"
      end
    end

    def on_complete(job_id, type, name)
      @mutex.synchronize { @completed[type] += 1 }
    end

    def on_fail(job_id, type, name, error)
      @mutex.synchronize do
        @failed[type] += 1
        label = PHASE_LABELS[type] || type.to_s
        @output.puts "#{RED}FAILED#{RESET} #{label} #{BOLD}#{name}#{RESET}: #{error.message}"
      end
    end

    def summary
      total_completed = @completed.values.sum
      total_failed = @failed.values.sum
      if total_failed > 0
        "#{total_completed} gems installed, #{total_failed} failed"
      else
        "#{total_completed} gems processed"
      end
    end

    private

    def total_jobs
      @total.values.sum
    end
  end
end
