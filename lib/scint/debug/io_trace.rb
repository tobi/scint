# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "../fs"

module Scint
  module Debug
    module IOTrace
      module_function

      @enabled = false
      @log_io = nil
      @log_path = nil
      @mutex = Thread::Mutex.new
      @patched = false
      @patches = []

      FILE_METHODS = %i[
        open read binread write binwrite rename link symlink unlink delete
        stat lstat exist? file? directory?
      ].freeze

      DIR_METHODS = %i[
        glob children entries mkdir chdir exist?
      ].freeze

      PROCESS_METHODS = %i[spawn].freeze

      KERNEL_METHODS = %i[system].freeze

      def enable!(path)
        expanded = File.expand_path(path)
        FS.mkdir_p(File.dirname(expanded))

        @mutex.synchronize do
          disable_unlocked if @enabled
          patch_methods!
          # Start a fresh trace per run to avoid mixing data across installs.
          @log_io = File.open(expanded, "w")
          @log_path = expanded
          @enabled = true
        end

        log("trace.start", path: expanded)
        true
      end

      def disable!
        @mutex.synchronize do
          disable_unlocked
          unpatch_methods!
        end
      end

      def enabled?
        @enabled
      end

      def log(op, **data)
        return unless @enabled
        return if Thread.current[:scint_iotrace_guard]

        Thread.current[:scint_iotrace_guard] = true
        begin
          payload = {
            ts: Time.now.utc.iso8601(6),
            op: op,
            pid: Process.pid,
            tid: Thread.current.object_id,
            data: sanitize(data),
          }

          loc = caller_locations(1, 8)&.find { |frame| frame.path && !frame.path.include?("io_trace.rb") }
          payload[:loc] = "#{loc.path}:#{loc.lineno}" if loc

          line = JSON.generate(payload)
          @mutex.synchronize do
            return unless @enabled && @log_io
            @log_io.write(line)
            @log_io.write("\n")
            @log_io.flush
          end
        rescue StandardError
          # Logging must never break install flow.
        ensure
          Thread.current[:scint_iotrace_guard] = false
        end
      end

      def patch_methods!
        return if @patched

        patch_singleton_methods(File, FILE_METHODS, "File")
        patch_singleton_methods(Dir, DIR_METHODS, "Dir")
        patch_singleton_methods(Process, PROCESS_METHODS, "Process")
        patch_instance_methods(Kernel, KERNEL_METHODS, "Kernel")

        @patched = true
      end

      def unpatch_methods!
        return unless @patched

        @patches.reverse_each do |entry|
          container = entry[:container]
          method_name = entry[:method]
          original_name = entry[:original]

          next unless container.method_defined?(original_name) || container.private_method_defined?(original_name)

          with_silenced_warnings do
            container.send(:alias_method, method_name, original_name)
          end
          container.send(:remove_method, original_name)

          visibility = entry[:visibility]
          container.send(visibility, method_name) if visibility
        end

        @patches.clear
        @patched = false
      end

      def patch_singleton_methods(target, methods, prefix)
        singleton = target.singleton_class

        methods.each do |method_name|
          next unless singleton.method_defined?(method_name) || singleton.private_method_defined?(method_name)

          patch_method(singleton, method_name, "#{prefix}.#{method_name}")
        end
      end

      def patch_instance_methods(mod, methods, prefix)
        methods.each do |method_name|
          next unless mod.method_defined?(method_name) || mod.private_method_defined?(method_name)

          patch_method(mod, method_name, "#{prefix}.#{method_name}")
        end
      end

      def patch_method(container, method_name, op_name)
        original_name = "__scint_iotrace_orig_#{method_name}".to_sym
        return if container.method_defined?(original_name) || container.private_method_defined?(original_name)

        visibility = method_visibility(container, method_name)

        container.send(:alias_method, original_name, method_name)
        if container.instance_methods(false).include?(method_name) ||
           container.private_instance_methods(false).include?(method_name) ||
           container.protected_instance_methods(false).include?(method_name)
          container.send(:remove_method, method_name)
        elsif container.method_defined?(method_name) || container.private_method_defined?(method_name) || container.protected_method_defined?(method_name)
          container.send(:undef_method, method_name)
        end
        with_silenced_warnings do
          container.send(:define_method, method_name) do |*args, **kwargs, &block|
            Scint::Debug::IOTrace.log(op_name, args: args, kwargs: kwargs)
            if kwargs.empty?
              send(original_name, *args, &block)
            else
              send(original_name, *args, **kwargs, &block)
            end
          end
        end

        container.send(visibility, method_name) if visibility

        @patches << {
          container: container,
          method: method_name,
          original: original_name,
          visibility: visibility,
        }
      end

      def method_visibility(container, method_name)
        return :private if container.private_method_defined?(method_name)
        return :protected if container.protected_method_defined?(method_name)
        return :public if container.method_defined?(method_name)

        nil
      end

      def with_silenced_warnings
        verbose = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = verbose
      end

      def disable_unlocked
        return unless @enabled || @log_io

        begin
          if @enabled && @log_io
            @log_io.write(JSON.generate({ ts: Time.now.utc.iso8601(6), op: "trace.stop", pid: Process.pid, tid: Thread.current.object_id }) + "\n")
            @log_io.flush
          end
        rescue StandardError
          nil
        end

        @enabled = false
        io = @log_io
        @log_io = nil
        @log_path = nil
        io&.close
      end

      def sanitize(value, depth = 0)
        return "..." if depth > 3

        case value
        when String
          value.length > 300 ? "#{value.byteslice(0, 300)}..." : value
        when Symbol, Numeric, TrueClass, FalseClass, NilClass
          value
        when Array
          value.first(10).map { |v| sanitize(v, depth + 1) }
        when Hash
          out = {}
          value.each do |k, v|
            out[sanitize(k, depth + 1)] = sanitize(v, depth + 1)
            break if out.length >= 20
          end
          out
        else
          value.to_s
        end
      end
    end
  end
end
