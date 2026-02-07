# frozen_string_literal: true

module Bundler2
  class WorkerPool
    POISON = :__bundler2_poison__

    attr_reader :size

    def initialize(size, name: "worker")
      @max_size = size
      @size = 0
      @name = name
      @queue = Thread::Queue.new
      @workers = []
      @started = false
      @stopped = false
      @mutex = Thread::Mutex.new
    end

    # Start worker threads. initial_count defaults to max_size for backward compat.
    # The block receives (job) and should return a result or raise.
    def start(initial_count = nil, &block)
      raise "already started" if @started
      raise "no block given" unless block

      @started = true
      @handler = block

      count = [initial_count || @max_size, @max_size].min
      spawn_workers(count)
    end

    # Grow the pool to target size (clamped to max). Never shrinks.
    # Safe to call from any thread.
    def grow_to(target)
      @mutex.synchronize do
        return unless @started && !@stopped
        target = [target, @max_size].min
        return if target <= @size

        spawn_workers(target - @size)
      end
    end

    # Enqueue a job. Returns the job hash for tracking.
    def enqueue(payload, &callback)
      raise "not started" unless @started
      raise "pool is stopped" if @stopped

      job = {
        payload: payload,
        state: :pending,
        result: nil,
        error: nil,
        callback: callback,
      }
      @queue.push(job)
      job
    end

    # Signal all workers to stop after finishing current work.
    def stop
      current_size = nil
      @mutex.synchronize do
        return if @stopped
        @stopped = true
        current_size = @size
      end

      current_size.times { @queue.push(POISON) }
      @workers.each { |w| w.join }
    end

    def running?
      @started && !@stopped
    end

    private

    # Must be called inside @mutex (or during init before threads start)
    def spawn_workers(count)
      base = @workers.size
      count.times do |i|
        @workers << Thread.new do
          Thread.current.name = "#{@name}-#{base + i}"
          loop do
            job = @queue.pop
            break if job == POISON
            begin
              job[:result] = @handler.call(job[:payload])
              job[:state] = :completed
            rescue => e
              job[:error] = e
              job[:state] = :failed
            end
            begin
              job[:callback]&.call(job)
            rescue => e
              $stderr.puts "Worker callback error: #{e.class}: #{e.message}"
              $stderr.puts e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
              job[:error] ||= e
            end
          end
        end
      end
      @size += count
    end
  end
end
