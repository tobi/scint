# frozen_string_literal: true

require_relative "test_helper"
require "bundler2/worker_pool"

class WorkerPoolTest < Minitest::Test
  def test_start_requires_handler_block
    pool = Bundler2::WorkerPool.new(1)
    assert_raises(RuntimeError) { pool.start }
  end

  def test_worker_pool_executes_jobs_and_callbacks
    pool = Bundler2::WorkerPool.new(2, name: "test")
    done = Thread::Queue.new

    pool.start(1) { |payload| payload * 2 }
    pool.enqueue(3) do |job|
      assert_equal :completed, job[:state]
      assert_equal 6, job[:result]
      done.push(true)
    end

    done.pop
    pool.stop

    assert_equal false, pool.running?
  end

  def test_grow_to_increases_worker_count_up_to_max
    pool = Bundler2::WorkerPool.new(3)
    pool.start(1) { |payload| payload }

    pool.grow_to(10)
    assert_equal 3, pool.size

    pool.stop
  end

  def test_callback_errors_are_captured_on_job
    pool = Bundler2::WorkerPool.new(1)
    done = Thread::Queue.new

    old_err = $stderr
    $stderr = StringIO.new
    pool.start(1) { |_payload| 42 }
    job_ref = pool.enqueue(:x) do |_job|
      raise "callback boom"
    ensure
      done.push(true)
    end

    done.pop
    pool.stop
    $stderr = old_err

    assert_equal :completed, job_ref[:state]
    refute_nil job_ref[:error]
    assert_includes job_ref[:error].message, "callback boom"
  ensure
    $stderr = old_err if old_err
  end
end
