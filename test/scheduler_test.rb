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
end
