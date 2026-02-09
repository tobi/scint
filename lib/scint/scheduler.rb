# frozen_string_literal: true

require_relative "worker_pool"
require_relative "progress"
require_relative "platform"

module Scint
  class Scheduler
    # Job types in priority order (lower index = higher priority)
    # Lower number = dispatched first when ready.
    # build_ext runs before IO work so compilation starts ASAP once deps are
    # met, while downloads/extracts/links fill remaining worker slots.
    PRIORITIES = {
      fetch_index: 0,
      git_clone:   1,
      resolve:     2,
      build_ext:   3,
      download:    4,
      extract:     5,
      link:        6,
      binstub:     7,
    }.freeze

    Job = Struct.new(:id, :type, :name, :payload, :state, :result, :error,
                     :depends_on, :enqueued_at, keyword_init: true)

    attr_reader :errors, :progress

    # max_workers: hard ceiling (default cpu_count * 2, capped at 50)
    # initial_workers: how many threads to start with (default 1 — grow dynamically)
    # per_type_limits: optional hash { job_type => max_concurrent }
    # Example: { build_ext: 1, binstub: 1, link: 30 }
    def initialize(max_workers: nil, initial_workers: 1, progress: nil, fail_fast: false, per_type_limits: {})
      @max_workers = [max_workers || Platform.cpu_count * 2, 50].min
      @initial_workers = [[initial_workers, 1].max, @max_workers].min
      @current_workers = @initial_workers
      @progress = progress || Progress.new
      @fail_fast = fail_fast
      @aborted = false

      @mutex = Thread::Mutex.new
      @cv = Thread::ConditionVariable.new

      @jobs = {}           # id => Job
      @pending = []        # sorted by priority
      @running = {}        # id => Job
      @completed = {}      # id => Job
      @failed = {}         # id => Job
      @running_by_type = Hash.new(0)
      @per_type_limits = normalize_per_type_limits(per_type_limits)

      @errors = []         # collected errors
      @next_id = 0
      @pool = nil
      @started = false
      @shutting_down = false
      @in_flight_follow_ups = 0  # track follow-ups being executed

      # Callbacks: type => [proc]
      @on_complete_callbacks = Hash.new { |h, k| h[k] = [] }

      # Waiters: type => [ConditionVariable]
      @type_waiters = Hash.new { |h, k| h[k] = [] }
    end

    def start
      return if @started
      @started = true
      @progress.start

      @pool = WorkerPool.new(@max_workers, name: "scheduler")
      @pool.start(@initial_workers) do |job|
        execute_job(job)
      end

      # Dispatcher thread: pulls from priority queue and feeds the pool
      @dispatcher = Thread.new do
        Thread.current.name = "scheduler-dispatch"
        begin
          dispatch_loop
        rescue Exception => e
          $stderr.puts "\n!!! DISPATCHER THREAD CRASHED !!!"
          $stderr.puts "Exception: #{e.class}: #{e.message}"
          $stderr.puts e.backtrace.first(10).map { |l| "  #{l}" }.join("\n")
          raise
        end
      end
    end

    # Enqueue a job. Returns the job id.
    # depends_on: array of job ids that must complete before this runs.
    # follow_up: proc that receives (job) and can enqueue more jobs.
    def enqueue(type, name, payload = nil, depends_on: [], follow_up: nil)
      raise "scheduler not started" unless @started
      raise "unknown job type: #{type}" unless PRIORITIES.key?(type)

      job = nil
      @mutex.synchronize do
        return nil if @aborted

        id = @next_id += 1
        job = Job.new(
          id: id,
          type: type,
          name: name,
          payload: { data: payload, follow_up: follow_up },
          state: :pending,
          depends_on: depends_on.dup,
        )
        @jobs[id] = job
        insert_pending(job)
        @cv.broadcast
      end

      @progress.on_enqueue(job.id, job.type, job.name)
      job.id
    end

    # Wait for all jobs of a specific type to complete.
    # Returns once no pending/running jobs of that type remain.
    def wait_for(type)
      @mutex.synchronize do
        loop do
          pending_of_type = @pending.any? { |j| j.type == type }
          running_of_type = @running.values.any? { |j| j.type == type }
          break if @aborted
          break unless pending_of_type || running_of_type
          @cv.wait(@mutex)
        end
      end
    end

    # Wait for a specific job to complete. Returns the Job.
    def wait_for_job(job_id)
      @mutex.synchronize do
        loop do
          job = @jobs[job_id]
          return job if job.nil? || job.state == :completed || job.state == :failed
          @cv.wait(@mutex)
        end
      end
    end

    # Wait for ALL jobs to finish (including any in-flight follow-ups).
    def wait_all
      @mutex.synchronize do
        loop do
          break if @running.empty? && @in_flight_follow_ups == 0 && (@pending.empty? || @aborted)
          @cv.wait(@mutex)
        end
      end
    end

    # Register a callback for when jobs of a given type complete.
    def on_complete(type, &block)
      @mutex.synchronize do
        @on_complete_callbacks[type] << block
      end
    end

    # Scale to exactly n workers (clamped to [current, max_workers]).
    # Never shrinks — if n < current workers, this is a no-op.
    def scale_to(n)
      return unless @pool
      target = [[n, @current_workers].max, @max_workers].min
      return if target <= @current_workers

      @pool.grow_to(target)
      @current_workers = target
    end

    # Auto-scale based on pending queue depth.
    # Formula: target = clamp(queue_depth / 4, 1, max_workers)
    def adjust_workers(queue_depth = nil)
      depth = queue_depth || @mutex.synchronize { @pending.size }
      target = [[1, (depth / 4.0).ceil].max, @max_workers].min
      scale_to(target)
    end

    # Scale worker count based on workload hint (e.g. gem count, download count).
    # Convenience wrapper: after Gemfile parse pass gem_count,
    # after resolution pass download_count.
    def scale_workers(hint)
      return unless @pool
      target = [[1, (hint / 3.0).ceil].max, @max_workers].min
      scale_to(target)
    end

    def current_workers
      @current_workers
    end

    def max_workers
      @max_workers
    end

    # Gracefully shut down: wait for all work, then stop threads.
    def shutdown
      return unless @started
      wait_all

      @mutex.synchronize { @shutting_down = true }
      @cv.broadcast
      @dispatcher&.join(5)
      @pool&.stop
      @progress.stop
      @started = false
    end

    def stats
      @mutex.synchronize do
        {
          pending: @pending.size,
          running: @running.size,
          completed: @completed.size,
          failed: @failed.size,
          total: @jobs.size,
          workers: @current_workers,
          max_workers: @max_workers,
        }
      end
    end

    def failed?
      @mutex.synchronize { !@failed.empty? || !@errors.empty? }
    end

    def aborted?
      @mutex.synchronize { @aborted }
    end

    private

    def dispatch_loop
      loop do
        job = nil

        @mutex.synchronize do
          loop do
            break if @shutting_down
            break if @aborted && @running.empty?
            if @aborted
              @cv.wait(@mutex)
              next
            end

            # Backpressure: keep at most @current_workers in-flight so a
            # fail-fast error can still halt most pending work.
            if @running.size >= @current_workers
              @cv.wait(@mutex)
              next
            end

            job = pick_ready_job
            break if job

            # Nothing ready yet — wait for state change
            @cv.wait(@mutex)
          end

          if job
            job.state = :running
            @running[job.id] = job
            @running_by_type[job.type] += 1
          end
        end

        break if (@shutting_down || (@aborted && job.nil?)) && job.nil?
        next unless job

        @progress.on_start(job.id, job.type, job.name)

        @pool.enqueue(job) do |pool_job|
          finished_job = pool_job[:payload]
          handle_completion(finished_job, pool_job[:error])
        end
      end
    end

    # Must be called inside @mutex
    def pick_ready_job
      @pending.each_with_index do |job, idx|
        next unless type_slot_available?(job.type)

        # Check if dependencies are met
        deps_met = job.depends_on.all? do |dep_id|
          dep = @jobs[dep_id]
          dep && (dep.state == :completed || dep.state == :failed)
        end

        if deps_met
          @pending.delete_at(idx)
          return job
        end
      end
      nil
    end

    # Insert into pending list maintaining priority order
    def insert_pending(job)
      priority = PRIORITIES[job.type] || 99
      idx = @pending.bsearch_index { |j| (PRIORITIES[j.type] || 99) > priority }
      if idx
        @pending.insert(idx, job)
      else
        @pending.push(job)
      end
    end

    def execute_job(job)
      data = job.payload[:data]
      if data.respond_to?(:call)
        data.call
      elsif data.is_a?(Hash) && data[:proc]
        data[:proc].call
      else
        data
      end
    end

    def handle_completion(job, error)
      follow_up = job.payload[:follow_up]
      callbacks = nil
      run_follow_up = false

      @mutex.synchronize do
        @running.delete(job.id)
        @running_by_type[job.type] -= 1 if @running_by_type[job.type] > 0

        if error
          job.state = :failed
          job.error = error
          @failed[job.id] = job
          @errors << { job_id: job.id, type: job.type, name: job.name, error: error }
          if @fail_fast
            @aborted = true
            # Drop queued work immediately; wait_all will return once current
            # in-flight jobs drain.
            @pending.clear
          end
        else
          job.state = :completed
          @completed[job.id] = job

          callbacks = @on_complete_callbacks[job.type].dup

          if follow_up && !@aborted
            run_follow_up = true
            @in_flight_follow_ups += 1
          end
        end

        @cv.broadcast
      end

      # Run progress callbacks outside mutex (they don't mutate scheduler state)
      if error
        @progress.on_fail(job.id, job.type, job.name, error)
      else
        @progress.on_complete(job.id, job.type, job.name)
        callbacks&.each { |cb| cb.call(job) }
      end

      # Run follow-up outside mutex so it can call enqueue without deadlock
      if run_follow_up
        begin
          follow_up.call(job)
        rescue => e
          @mutex.synchronize do
            @errors << { job_id: job.id, type: job.type, name: job.name, error: e, phase: :follow_up }
          end
        ensure
          @mutex.synchronize do
            @in_flight_follow_ups -= 1
            @cv.broadcast
          end
        end
      end
    end

    def normalize_per_type_limits(limits)
      out = {}
      limits.each do |type, limit|
        next unless PRIORITIES.key?(type)
        next if limit.nil?

        n = limit.to_i
        out[type] = n if n > 0
      end
      out
    end

    def type_slot_available?(type)
      limit = @per_type_limits[type]
      return true unless limit

      @running_by_type[type] < limit
    end
  end
end
