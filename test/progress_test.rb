# frozen_string_literal: true

require_relative "test_helper"
require "bundler2/progress"

class ProgressTest < Minitest::Test
  def test_summary_counts_completed_and_failed
    out = StringIO.new
    progress = Bundler2::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_complete(1, :link, "rack")

    progress.on_enqueue(2, :download, "bad")
    progress.on_start(2, :download, "bad")
    progress.on_fail(2, :download, "bad", StandardError.new("boom"))

    assert_equal "1 gems installed, 1 failed", progress.summary
    assert_includes out.string, "Installed rack"
    assert_includes out.string, "FAILED bad: boom"
  end
end
