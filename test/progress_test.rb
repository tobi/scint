# frozen_string_literal: true

require_relative "test_helper"
require "scint/progress"

class ProgressTest < Minitest::Test
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
    assert_includes out.string, "[1/1] Linking rack"
    assert_includes out.string, "[2/2] Downloading bad"
    assert_includes out.string, "FAILED Downloading bad: boom"
  end
end
