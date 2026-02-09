# frozen_string_literal: true

module Scint
  class Progress
    HIDDEN_TYPES = {
      binstub: true,
    }.freeze
    STREAM_TYPES = {
      download: true,
      extract: true,
      link: true,
      build_ext: true,
    }.freeze
    SETUP_TYPES = {
      fetch_index: true,
      git_clone: true,
      resolve: true,
    }.freeze
    BUILD_TAIL_MAX = 6
    BUILD_TAIL_PREVIEW_LINES = 4
    RENDER_HZ = 20
    RENDER_INTERVAL = 1.0 / RENDER_HZ
    MAX_DETAIL_ROWS_PER_PHASE = 4
    MAX_LINE_LEN = 220
    MIN_RENDER_WIDTH = 40
    MAX_PANEL_ROWS = 14
    SLOW_OPERATION_THRESHOLD_SECONDS = 1.0
    # Pulsing bullet: breathes from dark gray to ~#ccc and back.
    # Ease-out curve (decelerates near bright) via sqrt.
    # 256-color grayscale: 243=dark gray floor, 252≈#ccc ceiling.
    PULSE_FRAMES = begin
      lo, hi = 243, 255
      # Quick sweep through 6 mid-tones, longer holds at endpoints
      mid_up = (1..6).map { |i| lo + ((hi - lo) * (i / 7.0)).round }
      mid_down = mid_up[0..-2].reverse
      hold_dim = [lo] * 5
      hold_bright = [hi] * 4
      (hold_dim + mid_up + hold_bright + mid_down).map { |c| "\e[38;5;#{c}m•\e[0m" }.freeze
    end
    IDLE_MARK = "•".freeze
    PANEL_PHASE_ORDER = %i[download extract link build_ext].freeze
    COMPLETION_LOG_TYPES = {
      download: true,
      extract: true,
      link: true,
      build_ext: true,
    }.freeze

    PHASE_LABELS = {
      fetch_index: "Fetching index",
      git_clone: "Cloning",
      resolve: "Resolving",
      download: "Downloading",
      extract: "Extraction",
      link: "Installing",
      build_ext: "Compiling",
    }.freeze
    PHASE_SUMMARY_LABELS = {
      download: "Downloads",
      extract: "Extraction",
      link: "Installing",
      build_ext: "Compiling",
    }.freeze

    def initialize(output: $stderr)
      @output = output
      @interactive = tty_output?(@output)
      @render_width = detect_terminal_width(@output)
      @build_tail_width = [@render_width - 28, 40].max
      @mutex = Thread::Mutex.new
      @started = 0
      @completed = Hash.new(0)
      @failed = Hash.new(0)
      @total = Hash.new(0)
      @active_jobs = {}
      @job_started_at = {}
      @build_tail = []
      @build_tail_by_name = {}
      @pulse_idx = 0
      @live_rows = 0
      @rendered_widths = []
      @cursor_hidden = false
      @phase_started_at = {}
      @phase_finished = {}
      @phase_elapsed = {}
      @phase_reserved_detail_rows = Hash.new(0)
      @setup_lines_printed = false
      @setup_gap_printed = false
      @active_setup = nil  # { type:, name:, started_at: } for timed setup display
      @pending_log_lines = []
      @render_stop = false
      @render_thread = nil
    end

    def start
      return unless @interactive

      @mutex.synchronize do
        start_render_thread_locked
      end
      nil
    end

    def stop
      thread = nil
      @mutex.synchronize do
        @render_stop = true
        thread = @render_thread
      end
      thread&.join

      @mutex.synchronize do
        begin
          flush_pending_logs_locked
          mark_completed_phase_elapsed_locked
          render_live_locked if any_active_stream_jobs?
          if @interactive && @live_rows.positive?
            move_cursor_down(@live_rows - 1)
            @output.print "\r\n"
            @output.flush if @output.respond_to?(:flush)
            @live_rows = 0
            @rendered_widths = []
          end
          # Emit deferred phase summaries for interactive stream types
          PANEL_PHASE_ORDER.each { |type| emit_phase_completion_locked(type) }
        ensure
          show_cursor_locked
          @render_thread = nil
        end
      end
    end

    def on_enqueue(job_id, type, name)
      @mutex.synchronize do
        @total[type] += 1 unless hidden_type?(type)
      end
    end

    # Setup types that use a live timer in the live block (single-job only).
    TIMED_SETUP_TYPES = { resolve: true }.freeze

    def on_start(job_id, type, name)
      return if hidden_type?(type)

      @mutex.synchronize do
        @active_jobs[job_id] = { type: type, name: name }
        @job_started_at[job_id] = Process.clock_gettime(Process::CLOCK_MONOTONIC) if completion_log_type?(type)
        @started += 1
        @phase_started_at[type] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) if stream_type?(type)
        if @interactive
          start_render_thread_locked
          if TIMED_SETUP_TYPES[type]
            # Single-job setup with live timer (e.g. resolve)
            @active_setup = { type: type, name: name, started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          elsif setup_type?(type)
            # Concurrent-safe setup: just write scrollback immediately
            write_scrollback_line_locked(format_setup_or_log_line(type, name))
          else
            write_scrollback_line_locked(format_setup_or_log_line(type, name)) unless stream_type?(type)
          end
        else
          write_scrollback_line_locked(format_setup_or_log_line(type, name))
        end
      end
    end

    def on_complete(job_id, type, name)
      @mutex.synchronize do
        @completed[type] += 1
        active = @active_jobs.delete(job_id)
        @build_tail_by_name.delete(active[:name]) if active
        @job_started_at.delete(job_id)
        if @interactive && TIMED_SETUP_TYPES[type] && @active_setup && @active_setup[:type] == type
          finalize_setup_locked
        end
        emit_phase_completion_locked(type) if !@interactive || !stream_type?(type)
      end
    end

    def on_fail(job_id, type, name, error)
      return if hidden_type?(type)

      @mutex.synchronize do
        active = @active_jobs.delete(job_id)
        elapsed = consume_job_elapsed(job_id)
        @build_tail_by_name.delete(active[:name]) if active
        @failed[type] += 1
        label = PHASE_LABELS[type] || type.to_s
        failed_timing = if elapsed && elapsed >= SLOW_OPERATION_THRESHOLD_SECONDS
          " #{DIM}#{format_phase_elapsed(elapsed)}#{RESET}"
        else
          ""
        end
        failed_line = "#{RED}FAILED#{RESET} #{label} #{BOLD}#{name}#{RESET}: #{error.message}#{failed_timing}"
        if @interactive
          queue_log_line_locked(failed_line)
        else
          write_scrollback_line_locked(failed_line)
        end
        if !@interactive
          emit_phase_completion_locked(type)
        end
      end
    end

    # Accepts the latest build command output lines for one gem and prints
    # a rolling tail so native build activity is visible without log spam.
    def on_build_tail(name, lines)
      cleaned = Array(lines).map { |line| line.to_s.strip }.reject(&:empty?)
      return if cleaned.empty?

      @mutex.synchronize do
        truncated = cleaned.map { |line| truncate_plain(line, @build_tail_width) }
        truncated.each { |line| @build_tail << "#{name}: #{line}" }
        @build_tail = @build_tail.last(BUILD_TAIL_MAX)
        @build_tail_by_name[name] ||= []
        @build_tail_by_name[name].concat(truncated)
        @build_tail_by_name[name] = @build_tail_by_name[name].last(BUILD_TAIL_MAX)

        unless @interactive
          @output.puts "#{DIM}  build tail#{RESET}"
          @build_tail.last(4).each do |line|
            @output.puts "#{DIM}    #{truncate_plain(line, 180)}#{RESET}"
          end
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

    def hidden_type?(type)
      HIDDEN_TYPES[type] == true
    end

    def completion_log_type?(type)
      COMPLETION_LOG_TYPES[type] == true
    end

    def consume_job_elapsed(job_id)
      started_at = @job_started_at.delete(job_id)
      return nil unless started_at

      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    end

    def queue_log_line_locked(line)
      @pending_log_lines << line
    end

    def flush_pending_logs_locked
      return if @pending_log_lines.empty?

      lines = @pending_log_lines.dup
      @pending_log_lines.clear
      lines.each_with_index do |line, idx|
        write_scrollback_line_locked(line, flush: idx == lines.length - 1)
      end
    end

    def write_scrollback_line_locked(line, flush: true)
      rendered = fit_line(line, @render_width)

      unless @interactive && @live_rows.positive?
        @output.print "\r"
        @output.puts rendered
        @output.flush if flush && @output.respond_to?(:flush)
        return
      end

      # Insert one scrollback line above the live block.
      buf = +""
      buf << "\e[#{@live_rows}A" if @live_rows > 1
      buf << "\e[1L"                      # insert blank line, pushing live block down
      buf << "\r#{rendered}\e[K\n"
      buf << "\e[#{@live_rows - 1}B" if @live_rows > 1
      buf << "\r"
      @output.print buf
      @output.flush if flush && @output.respond_to?(:flush)
    end

    # Single-pass render: flush scrollback lines + redraw live block in one
    # buffered write to eliminate flicker from interleaved cursor movements.
    def render_frame_locked
      flush_pending_logs_locked
      if any_active_stream_jobs?
        render_live_locked
      elsif @active_setup
        render_setup_timer_locked
      end
    end

    def render_live_locked
      return unless @interactive
      return unless any_active_stream_jobs? || any_active_setup_jobs?

      mark_completed_phase_elapsed_locked

      lines = []
      pulse = PULSE_FRAMES[@pulse_idx % PULSE_FRAMES.length]
      @pulse_idx += 1

      if any_active_stream_jobs?
        lines.concat(phase_lines(pulse))
      else
        lines << "#{pulse} Processing..."
      end
      lines = clamp_panel_rows(lines)

      redraw_live_block_locked(lines)
    end

    def truncate_plain(text, max_len)
      return text if text.length <= max_len

      "#{text[0, max_len - 1]}…"
    end

    def setup_type?(type)
      SETUP_TYPES[type] == true
    end

    def render_setup_timer_locked
      return unless @interactive && @active_setup

      s = @active_setup
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - s[:started_at]
      label = PHASE_LABELS[s[:type]] || s[:type].to_s
      line = "#{DIM}#{label} #{s[:name]} (#{format_elapsed_short(elapsed)})#{RESET}"
      redraw_live_block_locked([line])
    end

    def finalize_setup_locked
      s = @active_setup
      return unless s

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - s[:started_at]
      label = PHASE_LABELS[s[:type]] || s[:type].to_s
      final = if TIMED_SETUP_TYPES[s[:type]]
        "#{label} #{s[:name]} #{DIM}(#{format_elapsed_short(elapsed)})#{RESET}"
      else
        "#{label} #{s[:name]}"
      end
      @active_setup = nil
      # Clear the live timer line, write final to scrollback
      redraw_live_block_locked([]) if @live_rows > 0
      write_scrollback_line_locked(final)
      @setup_lines_printed = true
    end

    def format_elapsed_short(seconds)
      if seconds < 10
        format("%.1fs", seconds)
      else
        format("%.0fs", seconds)
      end
    end

    def stream_type?(type)
      STREAM_TYPES[type] == true
    end

    def stream_active_or_pending?
      return true if STREAM_TYPES.keys.any? { |type| !active_stream_jobs_for(type).empty? }

      STREAM_TYPES.keys.any? do |type|
        @total[type].positive? && (@completed[type] + @failed[type] < @total[type])
      end
    end

    def any_stream_activity?
      STREAM_TYPES.keys.any? do |type|
        @total[type].positive? || @completed[type].positive? || @failed[type].positive? || !active_stream_jobs_for(type).empty?
      end
    end

    def phase_lines(pulse)
      # Show phases that have active jobs OR are still in-progress (started but not finished).
      # This prevents the panel from flickering when jobs briefly drain between dispatches.
      visible_types = PANEL_PHASE_ORDER.select do |type|
        next false if @total[type].zero?
        next false if @phase_finished[type]
        !active_stream_jobs_for(type).empty? || (@completed[type] + @failed[type] < @total[type])
      end
      visible_types.flat_map do |type|
        phase_rows_for(type, pulse)
      end
    end

    def phase_rows_for(type, pulse)
      active = active_stream_jobs_for(type)
      total = @total[type]
      completed = @completed[type] + @failed[type]
      total = completed if total < completed

      label = PHASE_SUMMARY_LABELS[type] || (PHASE_LABELS[type] || type.to_s)
      line = phase_status_line(type, active, label, completed, total, pulse)
      detail_rows = phase_detail_rows_for(type, active)
      [line, *detail_rows.first(MAX_DETAIL_ROWS_PER_PHASE)]
    end

    def phase_status_line(type, active_jobs, label, completed, total, pulse)
      w = [total.to_s.length, 4].max
      counter = "#{DIM}(#{completed.to_s.rjust(w)}/#{total})#{RESET}"
      base = "#{label} #{counter}"
      if active_jobs.empty?
        "#{pulse} #{base}"
      else
        name = active_jobs.first[:name]
        "#{pulse} #{base} · #{BOLD}#{name}#{RESET}"
      end
    end

    def phase_detail_rows_for(type, active_jobs)
      return [] if active_jobs.empty?

      return compile_tail_rows_for(active_jobs.first[:name]) if type == :build_ext

      []
    end

    def compile_tail_rows_for(name)
      tail = @build_tail_by_name[name]
      return [] if tail.nil? || tail.empty?

      tail.last(BUILD_TAIL_PREVIEW_LINES).map do |line|
        "#{DIM}    #{truncate_plain(line, @build_tail_width)}#{RESET}"
      end
    end

    def active_stream_jobs_for(type)
      @active_jobs.values.select { |job| job[:type] == type }
    end

    def any_active_stream_jobs?
      STREAM_TYPES.keys.any? { |type| !active_stream_jobs_for(type).empty? }
    end

    def any_active_setup_jobs?
      @active_jobs.values.any? { |job| SETUP_TYPES[job[:type]] == true }
    end

    def redraw_live_block_locked(lines)
      previous_rows = @live_rows

      if lines.empty? && previous_rows.zero?
        @live_rows = 0
        @rendered_widths = []
        return
      end

      hide_cursor_locked

      buf = +""
      buf << "\e[#{previous_rows - 1}A" if previous_rows > 1

      max_rows = [previous_rows, lines.length].max
      new_widths = []

      max_rows.times do |idx|
        line = idx < lines.length ? fit_line(lines[idx], @render_width) : ""
        new_widths << visible_width(line)
        buf << "\r#{line}\e[K"
        buf << "\n" if idx < (max_rows - 1)
      end

      buf << "\e[#{max_rows - lines.length}A" if max_rows > lines.length

      @output.print buf
      @output.flush if @output.respond_to?(:flush)
      @live_rows = lines.length
      @rendered_widths = new_widths.first(lines.length)
    end

    def clamp_panel_rows(lines)
      return lines if lines.length <= MAX_PANEL_ROWS

      clipped = lines.first(MAX_PANEL_ROWS - 1)
      clipped << "#{DIM}...#{RESET}"
      clipped
    end

    def move_cursor_up(lines)
      return if lines <= 0

      @output.print "\e[#{lines}A"
    end

    def move_cursor_down(lines)
      return if lines <= 0

      @output.print "\e[#{lines}B"
    end

    def start_render_thread_locked
      return if @render_thread&.alive?

      @render_stop = false
      @render_thread = Thread.new do
        loop do
          should_stop = false
          @mutex.synchronize do
            should_stop = @render_stop
            unless should_stop
              render_frame_locked
              should_stop = render_done_locked?
            end
          end
          break if should_stop
          sleep(RENDER_INTERVAL)
        end
      rescue StandardError
        nil
      end
    end

    def hide_cursor_locked
      return if @cursor_hidden

      @output.print "\e[?25l"
      @output.flush if @output.respond_to?(:flush)
      @cursor_hidden = true
    end

    def show_cursor_locked
      return unless @cursor_hidden

      @output.print "\e[?25h"
      @output.flush if @output.respond_to?(:flush)
      @cursor_hidden = false
    end

    def format_setup_or_log_line(type, name)
      label = PHASE_LABELS[type] || type.to_s
      if SETUP_TYPES[type]
        @setup_lines_printed = true
        "#{BOLD}#{label}#{RESET} #{name}"
      else
        "#{GREEN}[#{@started}/#{@total.values.sum}]#{RESET} #{label} #{BOLD}#{name}#{RESET}"
      end
    end

    def emit_setup_gap_if_needed(_type)
      # Intentionally empty — the live block provides visual separation.
    end

    def emit_phase_completion_locked(type)
      return unless stream_type?(type)
      return if @phase_finished[type]

      total = @total[type]
      return if total.zero?

      done = @completed[type] + @failed[type]
      return if done < total

      started_at = @phase_started_at[type] || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      failed = @failed[type]
      label = PHASE_SUMMARY_LABELS[type] || (PHASE_LABELS[type] || type.to_s)
      failure_suffix = failed.positive? ? " (#{failed} failed)" : ""
      @phase_elapsed[type] ||= elapsed
      line = "#{DIM}#{label}#{RESET} #{done}/#{total} in #{DIM}#{format_phase_elapsed(elapsed)}#{RESET}#{failure_suffix}"

      write_scrollback_line_locked(line)
      @phase_finished[type] = true
    end

    def mark_phase_elapsed_locked(type)
      return unless stream_type?(type)
      return if @phase_elapsed.key?(type)

      total = @total[type]
      return if total.zero?

      done = @completed[type] + @failed[type]
      return if done < total

      started_at = @phase_started_at[type] || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @phase_elapsed[type] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    end

    def mark_completed_phase_elapsed_locked
      PANEL_PHASE_ORDER.each do |type|
        total = @total[type]
        next if total.zero?
        next unless active_stream_jobs_for(type).empty?

        done = @completed[type] + @failed[type]
        mark_phase_elapsed_locked(type) if done >= total
      end
    end

    def render_done_locked?
      !any_active_stream_jobs? && !any_active_setup_jobs? &&
        @active_setup.nil? &&
        @pending_log_lines.empty? &&
        (!any_stream_activity? || !stream_active_or_pending?)
    end

    def format_phase_elapsed(seconds)
      ms = (seconds * 1000.0).round
      return "#{ms}ms" if ms < 1000

      format("%.2fs", seconds)
    end

    def fit_line(text, max_width)
      line = text.to_s
      return line if visible_width(line) <= max_width

      target = [max_width - 1, 1].max
      visible = 0
      out = +""

      line.scan(/\e\[[0-9;?]*[ -\/]*[@-~]|[^\e]+/).each do |token|
        if token.start_with?("\e[")
          out << token
          next
        end

        token.each_char do |ch|
          break if visible >= target
          out << ch
          visible += 1
        end
        break if visible >= target
      end

      "#{out}…"
    end

    def visible_width(text)
      text.to_s.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "").length
    end

    def detect_terminal_width(io)
      from_env = ENV["COLUMNS"].to_i
      width = from_env if from_env.positive?

      if width.nil? && io.respond_to?(:winsize)
        begin
          winsize = io.winsize
          width = winsize[1] if winsize && winsize[1].to_i.positive?
        rescue StandardError
          width = nil
        end
      end

      if width.nil?
        begin
          require "io/console"
          console = IO.console
          winsize = console&.winsize
          width = winsize[1] if winsize && winsize[1].to_i.positive?
        rescue StandardError
          width = nil
        end
      end

      width ||= MAX_LINE_LEN
      width = [width, MAX_LINE_LEN].min
      [width, MIN_RENDER_WIDTH].max
    end

    def tty_output?(io)
      io.respond_to?(:tty?) && io.tty?
    rescue StandardError
      false
    end
  end
end
