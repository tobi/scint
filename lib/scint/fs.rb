# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Scint
  module FS
    module_function

    # Cache of directories we've already ensured exist, to avoid repeated syscalls.
    @mkdir_cache = {}
    @mkdir_mutex = Thread::Mutex.new

    def mkdir_p(path)
      path = path.to_s
      return if @mkdir_cache[path]

      # Do the filesystem call outside the cache mutex so unrelated directory
      # creation can proceed in parallel across worker threads.
      FileUtils.mkdir_p(path)
      @mkdir_mutex.synchronize { @mkdir_cache[path] = true }
    end

    # APFS clonefile (CoW copy). Falls back to hardlink, then regular copy.
    def clonefile(src, dst)
      src = src.to_s
      dst = dst.to_s
      mkdir_p(File.dirname(dst))

      # Try APFS clonefile via cp -c (macOS)
      if Platform.macos?
        return if system("cp", "-c", src, dst, [:out, :err] => File::NULL)
      end

      # Fallback: hardlink
      begin
        File.link(src, dst)
        return
      rescue SystemCallError
        # cross-device or unsupported
      end

      # Final fallback: regular copy
      FileUtils.cp(src, dst)
    end

    # Recursively hardlink all files from src_dir into dst_dir.
    # Directory structure is recreated; files are hardlinked.
    def hardlink_tree(src_dir, dst_dir)
      src_dir = src_dir.to_s
      dst_dir = dst_dir.to_s
      raise Errno::ENOENT, src_dir unless Dir.exist?(src_dir)
      mkdir_p(dst_dir)

      queue = [[src_dir, dst_dir]]
      until queue.empty?
        src_root, dst_root = queue.shift

        Dir.each_child(src_root) do |entry|
          src_path = File.join(src_root, entry)
          dst_path = File.join(dst_root, entry)
          stat = File.lstat(src_path)

          if stat.directory?
            mkdir_p(dst_path)
            queue << [src_path, dst_path]
            next
          end

          mkdir_p(File.dirname(dst_path))
          begin
            File.link(src_path, dst_path)
          rescue SystemCallError
            FileUtils.cp(src_path, dst_path)
          end
        end
      end
    end

    # Atomic move: rename with cross-device fallback.
    def atomic_move(src, dst)
      src = src.to_s
      dst = dst.to_s
      mkdir_p(File.dirname(dst))

      begin
        File.rename(src, dst)
      rescue Errno::EXDEV
        # Cross-device: copy then remove
        tmp = "#{dst}.#{Process.pid}.#{Thread.current.object_id}"
        if File.directory?(src)
          FileUtils.cp_r(src, tmp)
        else
          FileUtils.cp(src, tmp)
        end
        File.rename(tmp, dst)
        FileUtils.rm_rf(src)
      end
    end

    # Create a temporary directory, yield it, clean up on error.
    def with_tempdir(prefix = "scint")
      dir = Dir.mktmpdir(prefix)
      yield dir
    rescue StandardError
      FileUtils.rm_rf(dir) if dir && File.exist?(dir)
      raise
    end

    # Write to a temp file then atomically rename into place.
    def atomic_write(path, content)
      path = path.to_s
      mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.binwrite(tmp, content)
      File.rename(tmp, path)
    end
  end
end
