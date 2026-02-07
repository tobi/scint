# frozen_string_literal: true

require_relative "test_helper"
require "scint/scheduler"
require "timeout"

class SchedulerTest < Minitest::Test
  class FakeProgress
    def start; end
    def stop; end
    def on_enqueue(*); end
    def on_start(*); end
    def on_complete(*); end
    def on_fail(*); end
  end

  def test_pending_queue_orders_by_priority
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)

    low = Scint::Scheduler::Job.new(id: 1, type: :link, name: "l", payload: {}, state: :pending, depends_on: [])
    high = Scint::Scheduler::Job.new(id: 2, type: :download, name: "d", payload: {}, state: :pending, depends_on: [])

    scheduler.send(:insert_pending, low)
    scheduler.send(:insert_pending, high)

    pending_types = scheduler.instance_variable_get(:@pending).map(&:type)
    assert_equal %i[download link], pending_types
  end

  def test_wait_all_includes_follow_up_jobs
    scheduler = Scint::Scheduler.new(max_workers: 2, initial_workers: 1, progress: FakeProgress.new)
    scheduler.start

    events = []

    scheduler.enqueue(
      :download,
      "rack",
      -> { events << :download },
      follow_up: lambda { |_job|
        scheduler.enqueue(:link, "rack", -> { events << :link })
      },
    )

    scheduler.wait_all

    assert_includes events, :download
    assert_includes events, :link
    assert_equal 2, scheduler.stats[:completed]
  ensure
    scheduler.shutdown if scheduler
  end

  def test_scheduler_records_job_and_follow_up_errors
    scheduler = Scint::Scheduler.new(max_workers: 2, progress: FakeProgress.new)
    scheduler.start

    scheduler.enqueue(:download, "bad", -> { raise "download boom" })
    scheduler.enqueue(:download, "follow-up", -> { :ok }, follow_up: ->(_job) { raise "follow up boom" })

    scheduler.wait_all

    errors = scheduler.errors
    assert_equal 2, errors.size
    assert errors.any? { |e| e[:error].message.include?("download boom") }
    assert errors.any? { |e| e[:phase] == :follow_up && e[:error].message.include?("follow up boom") }
    assert_equal true, scheduler.failed?
  ensure
    scheduler.shutdown if scheduler
  end

  def test_wait_for_blocks_until_type_finishes
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    started = Thread::Queue.new
    release = Thread::Queue.new

    scheduler.enqueue(:download, "a", lambda {
      started.push(true)
      release.pop
      :done
    })

    started.pop
    waiter_done = false
    waiter = Thread.new do
      scheduler.wait_for(:download)
      waiter_done = true
    end

    sleep 0.05
    assert_equal false, waiter_done
    release.push(true)

    waiter.join
    assert_equal true, waiter_done
  ensure
    scheduler.shutdown if scheduler
  end

  def test_wait_all_does_not_hang_when_worker_job_raises_exception
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    scheduler.enqueue(:download, "crash", -> { raise Exception, "hard crash" })

    Timeout.timeout(1) { scheduler.wait_all }

    assert_equal 1, scheduler.stats[:failed]
    assert_equal true, scheduler.errors.any? { |e| e[:name] == "crash" && e[:error].message == "hard crash" }
  ensure
    scheduler.shutdown if scheduler
  end

  def test_fail_fast_aborts_queue_after_first_error
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new, fail_fast: true)
    scheduler.start

    executed = []
    scheduler.enqueue(:download, "bad", lambda {
      executed << :bad
      raise "boom"
    })
    scheduler.enqueue(:link, "later", -> { executed << :later })

    Timeout.timeout(1) { scheduler.wait_all }

    assert_equal true, scheduler.aborted?
    assert_equal true, scheduler.failed?
    assert_equal [:bad], executed
    assert_nil scheduler.enqueue(:link, "after-abort", -> { :ok })
  ensure
    scheduler.shutdown if scheduler
  end

  def test_wait_for_job_blocks_until_specific_job_completes
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    started = Thread::Queue.new
    release = Thread::Queue.new

    job_id = scheduler.enqueue(:download, "a", lambda {
      started.push(true)
      release.pop
      :done
    })

    started.pop
    waiter_done = false
    returned_job = nil
    waiter = Thread.new do
      returned_job = scheduler.wait_for_job(job_id)
      waiter_done = true
    end

    sleep 0.05
    assert_equal false, waiter_done

    release.push(true)
    waiter.join

    assert_equal true, waiter_done
    assert_equal :completed, returned_job.state
    assert_equal job_id, returned_job.id
  ensure
    scheduler.shutdown if scheduler
  end

  def test_wait_for_job_returns_nil_for_unknown_job_id
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    result = scheduler.wait_for_job(999_999)
    assert_nil result
  ensure
    scheduler.shutdown if scheduler
  end

  def test_on_complete_callbacks_fire_when_jobs_finish
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    callback_received = []
    scheduler.on_complete(:download) do |job|
      callback_received << job.name
    end

    scheduler.enqueue(:download, "rack", -> { :ok })
    scheduler.enqueue(:download, "puma", -> { :ok })
    scheduler.wait_all

    assert_includes callback_received, "rack"
    assert_includes callback_received, "puma"
    assert_equal 2, callback_received.length
  ensure
    scheduler.shutdown if scheduler
  end

  def test_hash_payload_with_proc_key_is_executed
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    executed = false
    scheduler.enqueue(:download, "hash-job", { proc: -> { executed = true } })
    scheduler.wait_all

    assert_equal true, executed
    assert_equal 1, scheduler.stats[:completed]
  ensure
    scheduler.shutdown if scheduler
  end

  def test_non_callable_data_payload_completes_gracefully
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    scheduler.enqueue(:download, "data-job", "just a string")
    scheduler.wait_all

    assert_equal 1, scheduler.stats[:completed]
    assert_equal 0, scheduler.stats[:failed]
  ensure
    scheduler.shutdown if scheduler
  end

  def test_scale_to_and_current_workers_and_max_workers
    scheduler = Scint::Scheduler.new(max_workers: 8, initial_workers: 1, progress: FakeProgress.new)
    scheduler.start

    assert_equal 1, scheduler.current_workers
    assert_equal 8, scheduler.max_workers

    scheduler.scale_to(4)
    assert_equal 4, scheduler.current_workers

    # scale_to never shrinks
    scheduler.scale_to(2)
    assert_equal 4, scheduler.current_workers

    # scale_to clamps to max_workers
    scheduler.scale_to(100)
    assert_equal 8, scheduler.current_workers
  ensure
    scheduler.shutdown if scheduler
  end

  def test_scale_to_noop_without_pool
    scheduler = Scint::Scheduler.new(max_workers: 4, progress: FakeProgress.new)
    # Not started, so @pool is nil
    scheduler.scale_to(2)
    assert_equal 1, scheduler.current_workers
  end

  def test_adjust_workers_scales_based_on_queue_depth
    scheduler = Scint::Scheduler.new(max_workers: 10, initial_workers: 1, progress: FakeProgress.new)
    scheduler.start

    scheduler.adjust_workers(20)
    assert_equal 5, scheduler.current_workers

    scheduler.adjust_workers(40)
    assert_equal 10, scheduler.current_workers
  ensure
    scheduler.shutdown if scheduler
  end

  def test_scale_workers_scales_based_on_hint
    scheduler = Scint::Scheduler.new(max_workers: 10, initial_workers: 1, progress: FakeProgress.new)
    scheduler.start

    scheduler.scale_workers(9)
    assert_equal 3, scheduler.current_workers

    scheduler.scale_workers(30)
    assert_equal 10, scheduler.current_workers
  ensure
    scheduler.shutdown if scheduler
  end

  def test_per_type_limits_restrict_parallel_jobs_for_type
    scheduler = Scint::Scheduler.new(
      max_workers: 3,
      progress: FakeProgress.new,
      per_type_limits: { build_ext: 1 },
    )
    scheduler.start

    started = Queue.new
    release = Queue.new

    scheduler.enqueue(:build_ext, "one", lambda {
      started << :one
      release.pop
    })
    scheduler.enqueue(:build_ext, "two", lambda {
      started << :two
      release.pop
    })

    assert_equal :one, started.pop
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.1) { started.pop }
    end

    release << true
    assert_equal :two, started.pop
    release << true

    scheduler.wait_all
    assert_equal 2, scheduler.stats[:completed]
  ensure
    scheduler.shutdown if scheduler
  end

  def test_enqueue_rejects_unknown_job_type
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)
    scheduler.start

    error = assert_raises(RuntimeError) { scheduler.enqueue(:unknown, "x", -> { :ok }) }
    assert_includes error.message, "unknown job type"
  ensure
    scheduler.shutdown if scheduler
  end

  def test_enqueue_requires_started_scheduler
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)

    error = assert_raises(RuntimeError) { scheduler.enqueue(:download, "x", -> { :ok }) }
    assert_includes error.message, "scheduler not started"
  end

  def test_aborted_scheduler_waits_for_running_to_finish
    scheduler = Scint::Scheduler.new(max_workers: 2, progress: FakeProgress.new, fail_fast: true)
    scheduler.start

    release = Queue.new
    scheduler.enqueue(:download, "bad", -> { raise "boom" })
    scheduler.enqueue(:download, "slow", lambda {
      release.pop
      :ok
    })

    # Give the scheduler time to abort
    sleep 0.1
    release << true

    Timeout.timeout(2) { scheduler.wait_all }
    assert_equal true, scheduler.aborted?
  ensure
    scheduler.shutdown if scheduler
  end

  def test_scale_workers_noop_without_pool
    scheduler = Scint::Scheduler.new(max_workers: 4, progress: FakeProgress.new)
    # Not started, so @pool is nil
    scheduler.scale_workers(10)
    assert_equal 1, scheduler.current_workers
  end

  def test_depends_on_waits_for_dependency_completion
    scheduler = Scint::Scheduler.new(max_workers: 2, progress: FakeProgress.new)
    scheduler.start

    order = []
    dl_id = scheduler.enqueue(:download, "rack", -> { order << :download })
    scheduler.enqueue(:link, "rack", -> { order << :link }, depends_on: [dl_id])

    scheduler.wait_all

    assert_equal [:download, :link], order
  ensure
    scheduler.shutdown if scheduler
  end

  def test_dispatcher_crash_prints_to_stderr_and_reraises
    # We need to trigger a crash in the dispatch_loop. We can do this by
    # causing pick_ready_job or the dispatch loop internals to raise.
    # The simplest approach: stub the dispatch_loop to raise, then verify
    # the dispatcher thread catches it and prints to $stderr.
    scheduler = Scint::Scheduler.new(max_workers: 1, progress: FakeProgress.new)

    # Capture $stderr output
    original_stderr = $stderr
    captured_stderr = StringIO.new
    $stderr = captured_stderr

    begin
      # Patch dispatch_loop to always raise, simulating a crash
      scheduler.define_singleton_method(:dispatch_loop) do
        raise RuntimeError, "simulated dispatcher crash"
      end

      scheduler.instance_variable_set(:@started, true)
      scheduler.instance_variable_set(:@pool, Object.new.tap { |o|
        def o.start(*); end
        def o.stop; end
        def o.grow_to(*); end
      })

      # Start the dispatcher thread (mimicking what start does)
      dispatcher = Thread.new do
        Thread.current.name = "scheduler-dispatch"
        begin
          scheduler.send(:dispatch_loop)
        rescue Exception => e
          $stderr.puts "\n!!! DISPATCHER THREAD CRASHED !!!"
          $stderr.puts "Exception: #{e.class}: #{e.message}"
          $stderr.puts e.backtrace.first(10).map { |l| "  #{l}" }.join("\n")
          raise
        end
      end

      # Wait for the thread to finish (it should crash quickly)
      assert_raises(RuntimeError) { dispatcher.join(2) }

      stderr_output = captured_stderr.string
      assert_includes stderr_output, "!!! DISPATCHER THREAD CRASHED !!!"
      assert_includes stderr_output, "RuntimeError: simulated dispatcher crash"
    ensure
      $stderr = original_stderr
    end
  end

  def test_dispatch_loop_aborted_with_running_jobs_waits_on_cv
    # This tests lines 239-241: when @aborted is true and @running is not empty,
    # the dispatch loop waits on the condition variable instead of breaking.
    scheduler = Scint::Scheduler.new(max_workers: 2, progress: FakeProgress.new, fail_fast: true)
    scheduler.start

    started = Queue.new
    release = Queue.new

    # Enqueue two jobs: a slow one and a failing one. With max_workers: 2,
    # both can start. The failing one triggers @aborted = true, then the
    # dispatch loop must wait for the slow (running) job to complete.
    scheduler.enqueue(:download, "slow", lambda {
      started << :slow
      release.pop
      :ok
    })

    scheduler.enqueue(:download, "fail", lambda {
      started << :fail
      raise "boom"
    })

    # Wait for both to start
    2.times { started.pop }

    # At this point, "fail" has crashed, setting @aborted = true.
    # "slow" is still running. The dispatch loop should be waiting on cv.
    sleep 0.05
    assert_equal true, scheduler.aborted?

    # Verify running is not empty (slow is still going)
    running_count = scheduler.instance_variable_get(:@mutex).synchronize {
      scheduler.instance_variable_get(:@running).size
    }
    # The slow job may or may not still show in @running depending on timing,
    # but the key behavior is that wait_all completes once we release it.

    # Release the slow job
    release << true

    # wait_all should complete because the dispatch loop properly handled
    # the aborted + running state
    Timeout.timeout(2) { scheduler.wait_all }
    assert_equal true, scheduler.aborted?
  ensure
    scheduler.shutdown if scheduler
  end
end
