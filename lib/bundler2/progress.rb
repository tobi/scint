# frozen_string_literal: true

module Bundler2
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
      @completed = Hash.new(0)  # type => count
      @failed = Hash.new(0)     # type => count
      @total = Hash.new(0)      # type => count
    end

    def start
      nil
    end

    def stop
      nil
    end

    # Called when a job is enqueued
    def on_enqueue(job_id, type, name)
      @mutex.synchronize do
        @total[type] += 1
      end
    end

    # Called when a job starts running
    def on_start(job_id, type, name)
      @mutex.synchronize do
        @started += 1
        label = PHASE_LABELS[type] || type.to_s
        log_line("[#{@started}/#{total_jobs}] #{label} #{name}")
      end
    end

    # Called when a job completes
    def on_complete(job_id, type, name)
      @mutex.synchronize do
        @completed[type] += 1
      end
    end

    # Called when a job fails
    def on_fail(job_id, type, name, error)
      @mutex.synchronize do
        @failed[type] += 1
        label = PHASE_LABELS[type] || type.to_s
        log_line("FAILED #{label} #{name}: #{error.message}")
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

    def log_line(msg)
      @output.puts(msg)
    end

  end
end
