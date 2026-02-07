# frozen_string_literal: true

module Scint
  class Progress
    HIDDEN_TYPES = {
      binstub: true,
    }.freeze
    BUILD_TAIL_MAX = 6
    ACTIVE_PREVIEW_MAX = 5
    ACTIVE_PRINT_INTERVAL = 0.2

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
      @active_jobs = {}
      @build_tail = []
      @last_active_print_at = 0.0
    end

    def start = nil
    def stop = nil

    def on_enqueue(job_id, type, name)
      @mutex.synchronize do
        @total[type] += 1 unless hidden_type?(type)
      end
    end

    def on_start(job_id, type, name)
      return if hidden_type?(type)

      @mutex.synchronize do
        @active_jobs[job_id] = { type: type, name: name }
        @started += 1
        label = PHASE_LABELS[type] || type.to_s
        @output.puts "#{GREEN}[#{@started}/#{total_jobs}]#{RESET} #{label} #{BOLD}#{name}#{RESET}"
        emit_active_snapshot
      end
    end

    def on_complete(job_id, type, name)
      @mutex.synchronize do
        @completed[type] += 1
        @active_jobs.delete(job_id)
        emit_active_snapshot
      end
    end

    def on_fail(job_id, type, name, error)
      return if hidden_type?(type)

      @mutex.synchronize do
        @active_jobs.delete(job_id)
        @failed[type] += 1
        label = PHASE_LABELS[type] || type.to_s
        @output.puts "#{RED}FAILED#{RESET} #{label} #{BOLD}#{name}#{RESET}: #{error.message}"
        emit_active_snapshot(force: true)
      end
    end

    # Accepts the latest build command output lines for one gem and prints
    # a dim rolling tail to make native build progress easier to follow.
    def on_build_tail(name, lines)
      cleaned = Array(lines).map { |line| line.to_s.strip }.reject(&:empty?)
      return if cleaned.empty?

      @mutex.synchronize do
        cleaned.each { |line| @build_tail << "#{name}: #{line}" }
        @build_tail = @build_tail.last(BUILD_TAIL_MAX)

        @output.puts "#{DIM}  build tail#{RESET}"
        @build_tail.each do |line|
          @output.puts "#{DIM}    #{truncate(line, 180)}#{RESET}"
        end
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

    def hidden_type?(type)
      HIDDEN_TYPES[type] == true
    end

    def emit_active_snapshot(force: false)
      return if @active_jobs.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return unless force || (now - @last_active_print_at) >= ACTIVE_PRINT_INTERVAL

      active = @active_jobs.values
      preview = active.first(ACTIVE_PREVIEW_MAX).map do |job|
        label = PHASE_LABELS[job[:type]] || job[:type].to_s
        "#{label} #{job[:name]}"
      end
      more = active.length - preview.length
      line = preview.join("  |  ")
      line = "#{line}  +#{more} more" if more > 0
      @output.puts "#{DIM}  active: #{line}#{RESET}"
      @last_active_print_at = now
    end

    def truncate(text, max_len)
      return text if text.length <= max_len

      "#{text[0, max_len - 1]}…"
    end
  end
end
