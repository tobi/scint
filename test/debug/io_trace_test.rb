# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "scint/debug/io_trace"

class IOTraceTest < Minitest::Test
  def teardown
    Scint::Debug::IOTrace.disable!
  end

  def test_io_trace_logs_file_and_directory_operations
    with_tmpdir do |dir|
      trace = File.join(dir, "io-trace.jsonl")
      target = File.join(dir, "data.txt")

      Scint::Debug::IOTrace.enable!(trace)
      File.binwrite(target, "hello")
      File.binread(target)
      Dir.children(dir)
      Scint::Debug::IOTrace.disable!

      lines = File.readlines(trace)
      refute_empty lines

      ops = lines.map { |line| JSON.parse(line)["op"] }
      assert_includes ops, "File.binwrite"
      assert_includes ops, "File.binread"
      assert_includes ops, "Dir.children"
      assert_includes ops, "trace.start"
      assert_includes ops, "trace.stop"
    end
  end
end
