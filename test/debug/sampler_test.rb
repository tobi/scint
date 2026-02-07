# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "scint/debug/sampler"

class SamplerTest < Minitest::Test
  def test_sampler_writes_profile_report
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 200, max_depth: 20)

      sampler.start
      # keep VM busy so the sampler captures useful stacks
      10_000.times { "abc".upcase }
      sleep 0.05
      sampler.stop(exit_code: 0)

      assert File.exist?(out)
      data = JSON.parse(File.read(out))
      assert_equal "sampling", data["mode"]
      assert_equal 200, data["sample_hz"]
      assert_equal 0, data["exit_code"]
      assert_operator data["samples"], :>, 0
      assert_operator data["top_frames"].length, :>, 0
    end
  end

  def test_sampler_start_idempotent_when_already_running
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 100)

      sampler.start
      thread1 = sampler.instance_variable_get(:@thread)
      sampler.start
      thread2 = sampler.instance_variable_get(:@thread)

      # Should be the same thread -- start is idempotent
      assert_same thread1, thread2
    ensure
      sampler.stop(exit_code: 0)
    end
  end

  def test_sampler_handles_sample_error_gracefully
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 1000)

      sampler.start
      sleep 0.05
      sampler.stop(exit_code: 1)

      data = JSON.parse(File.read(out))
      assert_equal 1, data["exit_code"]
      assert data.key?("sample_errors")
    end
  end

  def test_sampler_thread_rescue_increments_sample_errors
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 100)

      # Stub sample_once to raise StandardError, which triggers the rescue
      # at line 47-48 (the thread-level rescue)
      call_count = 0
      sampler.define_singleton_method(:sample_once) do
        call_count += 1
        raise StandardError, "forced sample error"
      end

      sampler.start
      sleep 0.05
      sampler.stop(exit_code: 0)

      data = JSON.parse(File.read(out))
      assert_operator data["sample_errors"], :>=, 1, "sample_errors should be incremented by the thread rescue"
    end
  end

  def test_sampler_individual_thread_snapshot_rescue
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 50)

      # Create a fake thread that raises on backtrace_locations
      fake_thread = Object.new
      fake_thread.define_singleton_method(:==) { |other| false }
      fake_thread.define_singleton_method(:alive?) { true }
      fake_thread.define_singleton_method(:backtrace_locations) { raise StandardError, "snapshot error" }

      # Stub Thread.list to include the fake thread
      original_list = Thread.method(:list)
      Thread.stub(:list, -> { original_list.call + [fake_thread] }) do
        sampler.start
        sleep 0.1
        sampler.stop(exit_code: 0)
      end

      data = JSON.parse(File.read(out))
      assert_operator data["sample_errors"], :>=, 1, "sample_errors should be incremented by individual thread snapshot rescue"
    end
  end
end
