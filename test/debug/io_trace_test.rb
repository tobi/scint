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

  def test_enabled_returns_false_after_disable
    assert_equal false, Scint::Debug::IOTrace.enabled?
  end

  def test_method_visibility_returns_nil_for_undefined_method
    result = Scint::Debug::IOTrace.send(:method_visibility, String, :totally_nonexistent_method_xyz)
    assert_nil result
  end

  def test_sanitize_handles_deep_nesting
    result = Scint::Debug::IOTrace.send(:sanitize, { a: { b: { c: { d: "deep" } } } })
    # At depth 3, both key and value are sanitized at depth 4, returning "..."
    inner = result[:a][:b][:c]
    assert_equal({ "..." => "..." }, inner)
  end

  def test_sanitize_handles_non_standard_types
    result = Scint::Debug::IOTrace.send(:sanitize, Object.new)
    assert_kind_of String, result
  end

  def test_log_no_op_when_disabled
    # Should not raise or write anything
    Scint::Debug::IOTrace.log("test.op", foo: "bar")
  end

  def test_patched_method_forwards_kwargs
    with_tmpdir do |dir|
      trace = File.join(dir, "io-trace.jsonl")

      Scint::Debug::IOTrace.enable!(trace)

      # File.open with keyword argument (mode:) exercises the kwargs forwarding
      # path at line 154: send(original_name, *args, **kwargs, &block)
      target = File.join(dir, "kwargs_test.txt")
      File.open(target, mode: "w") { |f| f.write("kwargs") }
      content = File.read(target)
      assert_equal "kwargs", content

      Scint::Debug::IOTrace.disable!

      lines = File.readlines(trace)
      ops = lines.map { |line| JSON.parse(line)["op"] }
      assert_includes ops, "File.open"
    end
  end

  def test_disable_rescues_standard_error
    with_tmpdir do |dir|
      trace = File.join(dir, "io-trace.jsonl")
      Scint::Debug::IOTrace.enable!(trace)

      # Close the log IO so that writing the trace.stop entry raises an error
      log_io = Scint::Debug::IOTrace.instance_variable_get(:@log_io)
      log_io.close

      # disable! should rescue the StandardError (line 184-185) and not raise
      Scint::Debug::IOTrace.disable!
      refute Scint::Debug::IOTrace.enabled?
    end
  end
end
