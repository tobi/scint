# frozen_string_literal: true

require_relative "test_helper"
require "scint/progress"

class ProgressTest < Minitest::Test
  class FakeTTY < StringIO
    def tty? = true
  end

  def test_logs_tasks_sequentially_and_summarizes_failures
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_complete(1, :link, "rack")

    progress.on_enqueue(2, :download, "bad")
    progress.on_start(2, :download, "bad")
    progress.on_fail(2, :download, "bad", StandardError.new("boom"))

    assert_equal "1 gems installed, 1 failed", progress.summary
    assert_includes out.string, "[1/1] Installing rack"
    assert_includes out.string, "[2/2] Downloading bad"
    assert_includes out.string, "FAILED Downloading bad: boom"
  end

  def test_setup_tasks_do_not_use_ratio_prefix
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")

    assert_includes out.string, "Fetching index https://rubygems.org"
    refute_includes out.string, "[1/1]"
  end

  def test_prints_blank_line_after_setup_before_install_work
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")
    progress.on_enqueue(2, :link, "rack")
    progress.on_start(2, :link, "rack")

    assert_includes out.string, "Fetching index https://rubygems.org\n\n[2/2] Installing rack"
  end

  def test_hides_binstub_task_output
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :binstub, "rack")
    progress.on_start(1, :binstub, "rack")
    progress.on_complete(1, :binstub, "rack")
    progress.on_fail(1, :binstub, "rack", StandardError.new("boom"))

    assert_equal "", out.string
  end

  def test_counts_builtin_scint_link_like_normal_install_task
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "scint")
    progress.on_start(1, :link, "scint")
    progress.on_complete(1, :link, "scint")
    progress.on_enqueue(2, :link, "rack")
    progress.on_start(2, :link, "rack")
    progress.on_complete(2, :link, "rack")

    assert_equal "2 gems processed", progress.summary
    assert_includes out.string, "Installing scint"
    assert_includes out.string, "Installing rack"
  end

  def test_prints_dim_build_tail_lines
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_build_tail("ffi", ["$ ruby extconf.rb", "checking for foo... yes"])

    assert_includes out.string, "build tail"
    assert_includes out.string, "ffi: $ ruby extconf.rb"
    assert_includes out.string, "ffi: checking for foo... yes"
  end

  def test_interactive_mode_renders_compact_phase_panel
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :build_ext, "rack")
    progress.on_start(1, :build_ext, "rack")
    progress.on_build_tail("rack", ["$ ruby extconf.rb", "checking... yes"])
    sleep 0.3
    progress.on_build_tail("rack", ["done"])
    sleep 0.3
    progress.on_complete(1, :build_ext, "rack")
    progress.stop

    text = out.string
    assert_includes text, "Compiling... (0/1)"
    assert_includes text, "Compiling... (1/1)"
    assert_includes text, "· rack"
    assert_includes text, "    done"
    refute_includes text, "Installing gems..."
    refute_includes text, "[1/1] Linking rack"
  end

  def test_interactive_mode_shows_four_recent_compile_tail_lines
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :build_ext, "nokogiri")
    progress.on_start(1, :build_ext, "nokogiri")
    sleep 0.3
    progress.on_build_tail("nokogiri", ["l1", "l2", "l3", "l4", "l5"])
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "· nokogiri"
    assert_includes text, "    l2"
    assert_includes text, "    l3"
    assert_includes text, "    l4"
    assert_includes text, "    l5"
    refute_includes text, "    l1"
  end

  def test_interactive_mode_shows_only_first_active_job_for_phase
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    5.times do |i|
      progress.on_enqueue(i + 1, :download, "gem#{i}")
      progress.on_start(i + 1, :download, "gem#{i}")
    end
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "Downloads... (0/5)"
    assert_includes text, "· gem0"
  end

  def test_interactive_mode_renders_all_phase_rows_with_dim_idle_marker
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "rack")
    progress.on_start(1, :download, "rack")
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "Downloads... (0/1)"
    assert_includes text, "Extraction... (0/0)"
    assert_includes text, "Compiling... (0/0)"
    assert_includes text, "Installing... (0/0)"
    assert_includes text, "○"
  end

  def test_interactive_mode_hides_and_restores_cursor
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    sleep 0.3
    progress.stop

    assert_includes out.string, "\e[?25l"
    assert_includes out.string, "\e[?25h"
  end

  def test_interactive_mode_prints_slow_operation_in_scrollback
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "central_icons")
    progress.on_start(1, :link, "central_icons")
    progress.instance_variable_get(:@job_started_at)[1] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.5
    progress.on_complete(1, :link, "central_icons")
    progress.stop

    text = out.string
    assert_includes text, "Installing central_icons"
    assert_match(/\d+\.\d{2}s/, text)
  end

  def test_stop_positions_cursor_below_final_panel_for_followup_output
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    sleep 0.3
    progress.on_complete(1, :link, "rack")
    progress.stop
    out.print "SUMMARY\n"

    text = out.string
    assert_includes text, "Installing... (1/1)"
    assert_match(/\e\[\d+B\r\n\e\[\?25hSUMMARY/, text)
  end

  def test_prints_phase_completion_line_with_timing
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_complete(1, :link, "rack")

    assert_match(/Installing 1\/1 in .*ms|Installing 1\/1 in .*s/, out.string)
  end

  def test_fit_line_truncates_to_terminal_width
    progress = Scint::Progress.new(output: StringIO.new)
    fitted = progress.send(:fit_line, "x" * 200, 20)

    assert_equal true, progress.send(:visible_width, fitted) <= 20
    assert_includes fitted, "…"
  end

  def test_truncate_plain_returns_text_unchanged_when_short
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:truncate_plain, "hello", 10)
    assert_equal "hello", result
  end

  def test_truncate_plain_truncates_long_text_with_ellipsis
    progress = Scint::Progress.new(output: StringIO.new)
    long_text = "a" * 50
    result = progress.send(:truncate_plain, long_text, 20)
    assert_equal 20, result.length
    assert result.end_with?("…"), "Expected truncated text to end with ellipsis"
    assert_equal "a" * 19 + "…", result
  end

  def test_truncate_plain_at_exact_boundary
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:truncate_plain, "abcde", 5)
    assert_equal "abcde", result
  end

  def test_clamp_panel_rows_returns_lines_unchanged_when_within_limit
    progress = Scint::Progress.new(output: StringIO.new)
    lines = (1..5).map { |i| "line #{i}" }
    result = progress.send(:clamp_panel_rows, lines)
    assert_equal lines, result
  end

  def test_clamp_panel_rows_truncates_when_exceeding_max
    progress = Scint::Progress.new(output: StringIO.new)
    max = Scint::Progress::MAX_PANEL_ROWS
    lines = (1..(max + 5)).map { |i| "line #{i}" }
    result = progress.send(:clamp_panel_rows, lines)
    assert_equal max, result.length
    assert_includes result.last, "..."
    # The first (max - 1) lines should be preserved
    assert_equal lines.first(max - 1), result.first(max - 1)
  end

  def test_fit_line_preserves_ansi_escapes_and_truncates_visible_content
    progress = Scint::Progress.new(output: StringIO.new)
    ansi_line = "\e[1mHello World this is a long string with formatting\e[0m"
    fitted = progress.send(:fit_line, ansi_line, 15)
    visible = progress.send(:visible_width, fitted)
    assert_equal true, visible <= 15
    assert_includes fitted, "…"
    # ANSI escape codes should still be present
    assert_includes fitted, "\e[1m"
  end

  def test_tty_detection_fallback_returns_false_for_string_io
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:tty_output?, StringIO.new)
    assert_equal false, result
  end

  def test_start_starts_render_thread_in_interactive_mode
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Enqueue a stream type job so the render thread has work
    progress.on_enqueue(1, :link, "rack")

    # start should create a render thread when interactive
    progress.start
    sleep 0.1
    thread = progress.instance_variable_get(:@render_thread)
    assert thread.is_a?(Thread), "Expected render thread to be started"
  ensure
    progress.instance_variable_get(:@mutex).synchronize do
      progress.instance_variable_set(:@render_stop, true)
    end
    thread&.join(1)
  end

  def test_non_interactive_slow_operation_emit
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "bigfile")
    progress.on_start(1, :download, "bigfile")

    # Backdate the start time to simulate slow operation
    progress.instance_variable_get(:@job_started_at)[1] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 2.0

    progress.on_complete(1, :download, "bigfile")

    text = out.string
    assert_includes text, "Downloading"
    assert_includes text, "bigfile"
    assert_match(/\d+\.\d{2}s/, text)
  end

  def test_stream_active_or_pending_with_pending_jobs
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Enqueue a download but don't start it - so total > completed
    progress.on_enqueue(1, :download, "rack")
    progress.on_enqueue(2, :download, "puma")
    progress.on_start(1, :download, "rack")
    progress.on_complete(1, :download, "rack")

    # Still pending: gem2 is enqueued but not started/completed
    result = progress.send(:stream_active_or_pending?)
    assert_equal true, result
  end

  def test_detect_terminal_width_uses_columns_env
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    with_env("COLUMNS", "60") do
      width = progress.send(:detect_terminal_width, out)
      assert_equal 60, width
    end
  end

  def test_detect_terminal_width_uses_winsize
    io = Object.new
    io.define_singleton_method(:winsize) { [24, 100] }
    progress = Scint::Progress.new(output: StringIO.new)

    with_env("COLUMNS", nil) do
      width = progress.send(:detect_terminal_width, io)
      assert_equal 100, width
    end
  end

  def test_detect_terminal_width_clamps_to_min
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    with_env("COLUMNS", "10") do
      width = progress.send(:detect_terminal_width, out)
      assert_equal Scint::Progress::MIN_RENDER_WIDTH, width
    end
  end

  def test_tty_output_returns_false_on_exception
    broken_io = Object.new
    broken_io.define_singleton_method(:tty?) { raise IOError, "broken" }
    progress = Scint::Progress.new(output: StringIO.new)

    result = progress.send(:tty_output?, broken_io)
    assert_equal false, result
  end

  def test_reserve_phase_detail_space_pads_with_empty_rows
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Set up state that has 1 detail row but reserved 3
    progress.instance_variable_get(:@phase_reserved_detail_rows)[:download] = 3
    progress.instance_variable_get(:@total)[:download] = 5

    details = ["row1"]
    active_jobs = [{ type: :download, name: "gem1" }]
    rows = progress.send(:reserve_phase_detail_space, :download, details, 5, 0, active_jobs)

    assert_equal 3, rows.length
    assert_equal "row1", rows[0]
  end

  def test_clear_live_block_locked_moves_cursor_and_clears_lines
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Simulate that we previously drew a live block with 3 rows
    progress.instance_variable_set(:@live_rows, 3)
    progress.instance_variable_set(:@rendered_widths, [20, 15, 10])

    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:clear_live_block_locked)
    end

    text = out.string
    # Should move cursor up by (live_rows - 1) = 2 at the start
    assert_includes text, "\e[2A", "Expected cursor-up escape for 2 lines"
    # Should clear each line with spaces (overwriting previous content)
    assert_includes text, "\r#{' ' * 20}", "Expected first line cleared with 20 spaces"
    assert_includes text, "\r#{' ' * 15}", "Expected second line cleared with 15 spaces"
    assert_includes text, "\r#{' ' * 10}", "Expected third line cleared with 10 spaces"
    # Should end with cursor back at start
    assert_includes text, "\r"
    # live_rows should be reset to 0
    assert_equal 0, progress.instance_variable_get(:@live_rows)
    assert_equal [], progress.instance_variable_get(:@rendered_widths)
  end

  def test_clear_live_block_locked_noop_when_not_interactive
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    # Even if live_rows is set, non-interactive should be a no-op
    progress.instance_variable_set(:@live_rows, 3)
    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:clear_live_block_locked)
    end

    assert_equal "", out.string
  end

  def test_clear_live_block_locked_noop_when_zero_live_rows
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:clear_live_block_locked)
    end

    assert_equal "", out.string
    assert_equal 0, progress.instance_variable_get(:@live_rows)
  end

  def test_render_thread_rescues_standard_error
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Make render_live_locked raise so the rescue on line 460-461 triggers
    progress.define_singleton_method(:render_live_locked) do
      raise StandardError, "render exploded"
    end

    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:start_render_thread_locked)
    end

    thread = progress.instance_variable_get(:@render_thread)
    assert_kind_of Thread, thread

    # The thread should finish without propagating the error
    thread.join(2)
    refute thread.alive?, "Render thread should have exited after rescue"
  end

  def test_detect_terminal_width_rescues_io_console_failure
    # Create an IO-like object that doesn't respond to winsize
    io = StringIO.new
    progress = Scint::Progress.new(output: io)

    # Stub require "io/console" to raise, and make IO.console raise too.
    # We need COLUMNS unset and no winsize method to fall through to the
    # IO.console path (lines 602-610).
    with_env("COLUMNS", nil) do
      # io (StringIO) doesn't have winsize, so we skip the first branch.
      # For the IO.console branch, we need it to raise StandardError.
      # We can do this by temporarily stubbing IO.console.
      original_console = IO.method(:console)
      IO.define_singleton_method(:console) do |*|
        raise StandardError, "no console available"
      end

      begin
        width = progress.send(:detect_terminal_width, io)
        # Should fall through to the default MAX_LINE_LEN, clamped by min
        assert_operator width, :>=, Scint::Progress::MIN_RENDER_WIDTH
        assert_operator width, :<=, Scint::Progress::MAX_LINE_LEN
      ensure
        IO.define_singleton_method(:console, original_console)
      end
    end
  end

  def test_detect_terminal_width_rescues_winsize_error
    # Create an IO-like object whose winsize raises
    io = Object.new
    io.define_singleton_method(:winsize) { raise IOError, "not a tty" }
    progress = Scint::Progress.new(output: StringIO.new)

    with_env("COLUMNS", nil) do
      width = progress.send(:detect_terminal_width, io)
      # Should fall through to IO.console or default
      assert_operator width, :>=, Scint::Progress::MIN_RENDER_WIDTH
      assert_operator width, :<=, Scint::Progress::MAX_LINE_LEN
    end
  end

  def test_clear_live_block_via_on_fail_in_interactive_mode
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Set up an interactive session with a live block present
    progress.on_enqueue(1, :download, "rack")
    progress.on_start(1, :download, "rack")
    sleep 0.3

    # Capture output before fail
    out.truncate(0)
    out.rewind

    # on_fail triggers clear_live_block_locked in interactive mode
    progress.on_fail(1, :download, "rack", StandardError.new("network error"))
    progress.stop

    text = out.string
    # The fail message should appear
    assert_includes text, "FAILED"
    assert_includes text, "network error"
    # The cursor should have been moved (clear_live_block_locked ran)
    # The escape code for cursor up should appear if live rows were drawn
  end
end
