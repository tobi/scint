# frozen_string_literal: true

require "json"
require "time"
require_relative "../fs"

module Scint
  module Debug
    class Sampler
      DEFAULT_HZ = 250
      DEFAULT_MAX_DEPTH = 40

      def initialize(path:, hz: DEFAULT_HZ, max_depth: DEFAULT_MAX_DEPTH)
        @path = File.expand_path(path)
        @hz = [hz.to_i, 1].max
        @interval = 1.0 / @hz
        @max_depth = [max_depth.to_i, 1].max

        @mutex = Thread::Mutex.new
        @thread = nil
        @stop = false

        @started_at_wall = nil
        @started_at_mono = nil
        @finished_at_wall = nil

        @samples = 0
        @stack_counts = Hash.new(0)
        @frame_counts = Hash.new(0)
        @sample_errors = 0
      end

      def start
        return if @thread&.alive?

        @started_at_wall = Time.now.utc
        @started_at_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @stop = false

        @thread = Thread.new do
          loop do
            break if stop?

            sample_once
            sleep(@interval)
          end
        rescue StandardError
          @mutex.synchronize { @sample_errors += 1 }
        end
      end

      def stop(exit_code: nil)
        thread = nil
        @mutex.synchronize do
          @stop = true
          thread = @thread
        end
        thread&.join

        @finished_at_wall = Time.now.utc
        write_report(exit_code: exit_code)
      end

      private

      def stop?
        @mutex.synchronize { @stop }
      end

      def sample_once
        thread_snapshots = []

        Thread.list.each do |thr|
          next if thr == Thread.current
          next unless thr.alive?

          stack = thr.backtrace_locations
          next if stack.nil? || stack.empty?

          frames = stack.first(@max_depth).map { |loc| frame_string(loc) }
          next if frames.empty?

          thread_snapshots << frames
        rescue StandardError
          @mutex.synchronize { @sample_errors += 1 }
        end

        @mutex.synchronize do
          thread_snapshots.each do |frames|
            @samples += 1
            @stack_counts[frames.join(";")] += 1
            @frame_counts[frames.first] += 1
          end
        end
      end

      def frame_string(loc)
        path = loc.path || "(unknown)"
        "#{path}:#{loc.lineno}:in `#{loc.base_label}`"
      end

      def write_report(exit_code:)
        finished_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        started_mono = @started_at_mono || finished_mono
        elapsed_ms = ((finished_mono - started_mono) * 1000.0).round

        report = {
          version: 1,
          mode: "sampling",
          sample_hz: @hz,
          max_depth: @max_depth,
          started_at: (@started_at_wall || Time.now.utc).iso8601(6),
          finished_at: (@finished_at_wall || Time.now.utc).iso8601(6),
          wall_ms: elapsed_ms,
          exit_code: exit_code,
          samples: @samples,
          unique_stacks: @stack_counts.size,
          sample_errors: @sample_errors,
          top_frames: top_entries(@frame_counts, 50),
          top_stacks: top_entries(@stack_counts, 200),
          gc: {
            count: GC.count,
            total_allocated_objects: GC.stat(:total_allocated_objects),
            heap_live_slots: GC.stat(:heap_live_slots),
          },
        }

        FS.atomic_write(@path, JSON.pretty_generate(report))
      end

      def top_entries(hash, limit)
        hash.sort_by { |_k, v| -v }.first(limit).map do |key, count|
          { key: key, samples: count }
        end
      end
    end
  end
end
