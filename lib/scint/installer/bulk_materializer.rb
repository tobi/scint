# frozen_string_literal: true

require_relative "../fs"
require_relative "../platform"

module Scint
  module Installer
    # Thread-safe batch materializer that accumulates gem directories and
    # copies them to .bundle in bulk `cp -cR` calls instead of per-gem
    # process spawns. This dramatically reduces process-spawn overhead
    # on cold installs (820 gems × 1 cp each → a handful of batched calls).
    class BulkMaterializer
      BATCH_SIZE = 64

      def initialize(dst_parent)
        @dst_parent = dst_parent
        @pending = []    # [source_dir, ...]
        @mu = Thread::Mutex.new
        @flushing = Thread::ConditionVariable.new
        @flush_active = false
        FS.mkdir_p(@dst_parent)
      end

      # Register a gem for bulk materialization. If the gem already exists
      # at the destination, returns immediately. Otherwise queues it and
      # triggers a flush if the batch is full. Blocks until the gem is
      # materialized (either by this thread's flush or another's).
      def materialize(source_dir, gem_name)
        dest = File.join(@dst_parent, gem_name)
        return if Dir.exist?(dest)

        @mu.synchronize do
          # Double-check after acquiring lock
          return if Dir.exist?(dest)
          @pending << source_dir
          if @pending.size >= BATCH_SIZE
            flush_locked
          end
        end

        # Wait until our gem appears (another thread may be flushing)
        until Dir.exist?(dest)
          @mu.synchronize do
            return if Dir.exist?(dest)
            # If nobody is flushing and we still have pending items, flush now
            unless @flush_active
              flush_locked if @pending.any?
            end
            # Wait briefly for an active flush to complete
            @flushing.wait(@mu, 0.05) if @flush_active && !Dir.exist?(dest)
          end
        end
      end

      # Flush all remaining pending gems. Called after scheduler completes.
      def flush
        @mu.synchronize { flush_locked }
      end

      private

      def flush_locked
        return if @pending.empty?

        @flush_active = true
        batch = @pending.dup
        @pending.clear

        # Release lock during the actual copy
        @mu.unlock
        begin
          do_bulk_copy(batch)
        ensure
          @mu.lock
          @flush_active = false
          @flushing.broadcast
        end
      end

      def do_bulk_copy(sources)
        sources = sources.select { |s| Dir.exist?(s) }
        sources.reject! { |s| Dir.exist?(File.join(@dst_parent, File.basename(s))) }
        return if sources.empty?

        if Platform.macos?
          system("cp", "-cR", *sources, @dst_parent, [:out, :err] => File::NULL) ||
            sources.each { |s| FS.clone_tree(s, File.join(@dst_parent, File.basename(s))) }
        elsif Platform.linux?
          system("cp", "--reflink=auto", "-R", *sources, @dst_parent, [:out, :err] => File::NULL) ||
            sources.each { |s| FS.clone_tree(s, File.join(@dst_parent, File.basename(s))) }
        else
          sources.each { |s| FS.clone_tree(s, File.join(@dst_parent, File.basename(s))) }
        end
      end
    end
  end
end
