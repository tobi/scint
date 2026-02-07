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
    RENDER_HZ = 5
    RENDER_INTERVAL = 1.0 / RENDER_HZ
    MAX_DETAIL_ROWS_PER_PHASE = 4
    MAX_LINE_LEN = 220
    MIN_RENDER_WIDTH = 40
    MAX_PANEL_ROWS = 14
    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    IDLE_MARK = "○".freeze
    PANEL_PHASE_ORDER = %i[download extract build_ext link].freeze

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
      @build_tail = []
      @build_tail_by_name = {}
      @spinner_idx = 0
      @live_rows = 0
      @rendered_widths = []
      @cursor_hidden = false
      @phase_started_at = {}
      @phase_finished = {}
      @phase_elapsed = {}
      @phase_reserved_detail_rows = Hash.new(0)
      @setup_lines_printed = false
      @setup_gap_printed = false
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
          mark_completed_phase_elapsed_locked
          render_live_locked if any_stream_activity?
          if @interactive && @live_rows.positive?
            move_cursor_down(@live_rows - 1)
            @output.print "\r\n"
            @output.flush if @output.respond_to?(:flush)
            # Final frame is now in scrollback; clear live-block tracking so
            # repeated stop calls do not move/overwrite previously rendered rows.
            @live_rows = 0
            @rendered_widths = []
          end
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

    def on_start(job_id, type, name)
      return if hidden_type?(type)

      @mutex.synchronize do
        @active_jobs[job_id] = { type: type, name: name }
        @started += 1
        emit_setup_gap_if_needed(type)
        @phase_started_at[type] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) if stream_type?(type)
        if @interactive && stream_type?(type)
          start_render_thread_locked
        else
          clear_live_block_locked
          emit_setup_or_log_line(type, name)
        end
      end
    end

    def on_complete(job_id, type, name)
      @mutex.synchronize do
        @completed[type] += 1
        active = @active_jobs.delete(job_id)
        @build_tail_by_name.delete(active[:name]) if active
        if !@interactive || !stream_type?(type)
          emit_phase_completion_locked(type)
        end
      end
    end

    def on_fail(job_id, type, name, error)
      return if hidden_type?(type)

      @mutex.synchronize do
        active = @active_jobs.delete(job_id)
        @build_tail_by_name.delete(active[:name]) if active
        @failed[type] += 1
        clear_live_block_locked
        label = PHASE_LABELS[type] || type.to_s
        @output.puts "#{RED}FAILED#{RESET} #{label} #{BOLD}#{name}#{RESET}: #{error.message}"
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

    def render_live_locked
      return unless @interactive
      return unless any_stream_activity?

      mark_completed_phase_elapsed_locked

      lines = []
      spinner = SPINNER_FRAMES[@spinner_idx % SPINNER_FRAMES.length]
      @spinner_idx += 1

      lines.concat(phase_lines(spinner))
      lines = clamp_panel_rows(lines)

      redraw_live_block_locked(lines)
    end

    def truncate_plain(text, max_len)
      return text if text.length <= max_len

      "#{text[0, max_len - 1]}…"
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

    def phase_lines(spinner)
      PANEL_PHASE_ORDER.flat_map do |type|
        phase_rows_for(type, spinner)
      end
    end

    def phase_rows_for(type, spinner)
      active = active_stream_jobs_for(type)
      total = @total[type]
      completed = @completed[type] + @failed[type]
      total = completed if total < completed

      label = PHASE_SUMMARY_LABELS[type] || (PHASE_LABELS[type] || type.to_s)
      line = phase_status_line(type, active, label, completed, total, spinner)
      detail_rows = phase_detail_rows_for(type, active)
      [line, *reserve_phase_detail_space(type, detail_rows, total, completed, active)]
    end

    def phase_status_line(type, active_jobs, label, completed, total, spinner)
      base = "#{label}... (#{completed}/#{total})"
      if active_jobs.empty?
        elapsed = @phase_elapsed[type]
        elapsed_text = elapsed ? " · #{format_phase_elapsed(elapsed)}" : ""
        "#{DIM}#{IDLE_MARK} #{base}#{elapsed_text}#{RESET}"
      else
        name = active_jobs.first[:name]
        "#{spinner} #{base} · #{BOLD}#{name}#{RESET}"
      end
    end

    def phase_detail_rows_for(type, active_jobs)
      return [] if active_jobs.empty?

      if type == :build_ext
        compile_tail_rows_for(active_jobs.first[:name])
      else
        active_rows_for(type, active_jobs)
      end
    end

    def reserve_phase_detail_space(type, details, total, completed, active_jobs)
      if phase_complete?(type, total, completed, active_jobs)
        @phase_reserved_detail_rows[type] = 0
        return []
      end

      desired = [details.length, MAX_DETAIL_ROWS_PER_PHASE].min
      @phase_reserved_detail_rows[type] = [@phase_reserved_detail_rows[type], desired].max
      reserved = @phase_reserved_detail_rows[type]

      rows = details.first(reserved)
      while rows.length < reserved
        rows << "#{DIM}  #{RESET}"
      end
      rows
    end

    def phase_complete?(type, total, completed, active_jobs)
      return false if total.zero?

      if completed >= total && active_jobs.empty?
        mark_phase_elapsed_locked(type)
        return true
      end

      false
    end

    def active_rows_for(_type, active_jobs)
      return [] if active_jobs.empty?
      if active_jobs.length <= MAX_DETAIL_ROWS_PER_PHASE
        return active_jobs.map { |job| "  #{BOLD}#{job[:name]}#{RESET}" }
      end

      rows = active_jobs.first(MAX_DETAIL_ROWS_PER_PHASE - 1).map { |job| "  #{BOLD}#{job[:name]}#{RESET}" }
      remaining = active_jobs.length - rows.length
      rows << "#{DIM}  +#{remaining} more#{RESET}"
      rows
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

    def clear_live_block_locked
      return unless @interactive
      return if @live_rows.zero?

      move_cursor_up(@live_rows - 1)
      @live_rows.times do |idx|
        prev_width = @rendered_widths[idx] || 0
        @output.print "\r#{' ' * prev_width}"
        @output.print "\n" if idx < (@live_rows - 1)
      end
      move_cursor_up(@live_rows - 1)
      @output.print "\r"
      @output.flush if @output.respond_to?(:flush)
      @live_rows = 0
      @rendered_widths = []
    end

    def redraw_live_block_locked(lines)
      hide_cursor_locked
      previous_rows = @live_rows
      previous_widths = @rendered_widths.dup

      move_cursor_up(previous_rows - 1) if previous_rows.positive?

      max_rows = [previous_rows, lines.length].max
      new_widths = []

      max_rows.times do |idx|
        line = idx < lines.length ? fit_line(lines[idx], @render_width) : ""
        prev_width = previous_widths[idx] || 0
        line_width = visible_width(line)
        pad_len = prev_width > line_width ? (prev_width - line_width) : 0
        pad = pad_len.positive? ? (" " * pad_len) : ""

        @output.print "\r#{line}#{pad}"
        @output.print "\n" if idx < (max_rows - 1)
        new_widths << line_width
      end

      move_cursor_up(max_rows - lines.length) if max_rows > lines.length
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
              render_live_locked
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

    def emit_setup_or_log_line(type, name)
      label = PHASE_LABELS[type] || type.to_s
      if SETUP_TYPES[type]
        @output.puts "#{BOLD}#{label}#{RESET} #{name}"
        @setup_lines_printed = true
      else
        @output.puts "#{GREEN}[#{@started}/#{@total.values.sum}]#{RESET} #{label} #{BOLD}#{name}#{RESET}"
      end
    end

    def emit_setup_gap_if_needed(type)
      return if @setup_gap_printed
      return unless stream_type?(type)
      return unless @setup_lines_printed

      @output.puts
      @setup_gap_printed = true
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

      clear_live_block_locked if @interactive
      @output.print "\r"
      @output.puts line
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
      any_stream_activity? && !stream_active_or_pending?
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
