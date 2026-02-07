# frozen_string_literal: true

module Bundler2
  class Progress
    SPINNER = ["|", "/", "-", "\\"].freeze
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
      @tty = tty?
      @mutex = Thread::Mutex.new
      @active_jobs = {}   # job_id => {type:, name:, started_at:}
      @completed = Hash.new(0)  # type => count
      @failed = Hash.new(0)     # type => count
      @total = Hash.new(0)      # type => count
      @tick = 0
      @timer = nil
      @stopped = false
    end

    def start
      return unless @tty
      @stopped = false
      @timer = Thread.new do
        Thread.current.name = "progress-timer"
        loop do
          break if @stopped
          sleep 0.1
          render
        end
      end
    end

    def stop
      @stopped = true
      @timer&.join(1)
      @timer = nil
      clear_line if @tty
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
        @active_jobs[job_id] = { type: type, name: name, started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end
    end

    # Called when a job completes
    def on_complete(job_id, type, name)
      @mutex.synchronize do
        @active_jobs.delete(job_id)
        @completed[type] += 1
      end
      log_simple("Installed #{name}") if type == :link || type == :build_ext
    end

    # Called when a job fails
    def on_fail(job_id, type, name, error)
      @mutex.synchronize do
        @active_jobs.delete(job_id)
        @failed[type] += 1
      end
      log_simple("FAILED #{name}: #{error.message}")
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

    def tty?
      @output.respond_to?(:tty?) && @output.tty?
    end

    def render
      @mutex.synchronize do
        @tick += 1
        spinner = SPINNER[@tick % SPINNER.size]

        jobs = @active_jobs.values.first(4)
        return if jobs.empty?

        parts = jobs.map do |j|
          label = PHASE_LABELS[j[:type]] || j[:type].to_s
          "#{label} #{j[:name]}"
        end

        extra = @active_jobs.size - 4
        suffix = extra > 0 ? " (+#{extra} more)" : ""

        total_done = @completed.values.sum
        total_all = @total.values.sum

        line = "#{spinner} [#{total_done}/#{total_all}] #{parts.join(' | ')}#{suffix}"
        write_line(line)
      end
    end

    def write_line(text)
      return unless @tty
      cols = console_width
      truncated = text.length > cols ? text[0, cols - 1] + ">" : text
      @output.print("\r\e[K#{truncated}")
      @output.flush
    end

    def clear_line
      @output.print("\r\e[K")
      @output.flush
    end

    def log_simple(msg)
      if @tty
        clear_line
        @output.puts(msg)
      else
        @output.puts(msg)
      end
    end

    def console_width
      if @output.respond_to?(:winsize)
        begin
          _, cols = @output.winsize
          return cols if cols > 0
        rescue StandardError
          # ignore
        end
      end
      80
    end
  end
end
