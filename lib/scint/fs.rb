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

      # Try Linux reflink copy-on-write where supported (btrfs/xfs/etc).
      if Platform.linux?
        return if system("cp", "--reflink=always", src, dst, [:out, :err] => File::NULL)
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

    # Recursively clone directory tree from src_dir into dst_dir.
    # On macOS/APFS, prefers CoW clones via `cp -cR`.
    # Falls back to hardlink_tree, then regular copy per-file if needed.
    def clone_tree(src_dir, dst_dir)
      src_dir = src_dir.to_s
      dst_dir = dst_dir.to_s
      raise Errno::ENOENT, src_dir unless Dir.exist?(src_dir)
      mkdir_p(dst_dir)

      # Fast path on macOS/APFS: copy-on-write clone of full tree.
      if Platform.macos?
        src_contents = File.join(src_dir, ".")
        return if system("cp", "-cR", src_contents, dst_dir, [:out, :err] => File::NULL)
      end

      # Fast path on Linux filesystems with reflink support.
      if Platform.linux?
        src_contents = File.join(src_dir, ".")
        return if system("cp", "--reflink=always", "-R", src_contents, dst_dir, [:out, :err] => File::NULL)
      end

      hardlink_tree(src_dir, dst_dir)
    end

    # Materialize a tree using a manifest to avoid directory scans.
    # Manifest entries must be hashes with "path" and "type" keys.
    def materialize_from_manifest(src_dir, dst_dir, entries)
      src_dir = src_dir.to_s
      dst_dir = dst_dir.to_s
      entries = Array(entries)
      raise Errno::ENOENT, src_dir unless Dir.exist?(src_dir)
      mkdir_p(dst_dir)

      entries.each do |entry|
        rel = entry["path"].to_s
        next if rel.empty? || rel.start_with?("/") || rel.include?("..")

        src_path = File.join(src_dir, rel)
        dst_path = File.join(dst_dir, rel)

        case entry["type"]
        when "dir"
          mkdir_p(dst_path)
        when "symlink"
          mkdir_p(File.dirname(dst_path))
          next if File.exist?(dst_path) || File.symlink?(dst_path)

          target = File.readlink(src_path)
          begin
            File.symlink(target, dst_path)
          rescue Errno::EEXIST
            next
          end
        else
          mkdir_p(File.dirname(dst_path))
          next if File.exist?(dst_path)

          begin
            clonefile(src_path, dst_path)
          rescue Errno::EEXIST
            next
          rescue SystemCallError
            next if File.exist?(dst_path)
            raise
          end
        end
      end
    end

    # Clone many source directories into one destination parent directory.
    # This is significantly faster than one process per gem on large warm
    # installs because it batches cp invocations while preserving CoW/reflink.
    # Returns the number of source trees requested.
    def clone_many_trees(src_dirs, dst_parent, chunk_size: 64)
      dst_parent = dst_parent.to_s
      mkdir_p(dst_parent)

      sources = Array(src_dirs).map(&:to_s).uniq
      sources.select! { |src| Dir.exist?(src) }
      return 0 if sources.empty?

      copied = 0
      sources.each_slice([chunk_size.to_i, 1].max) do |slice|
        pending = slice.reject do |src|
          Dir.exist?(File.join(dst_parent, File.basename(src)))
        end
        next if pending.empty?

        ok = false
        if Platform.macos?
          ok = system("cp", "-cR", *pending, dst_parent, [:out, :err] => File::NULL)
        elsif Platform.linux?
          ok = system("cp", "--reflink=always", "-R", *pending, dst_parent, [:out, :err] => File::NULL)
        end

        unless ok
          pending.each do |src|
            clone_tree(src, File.join(dst_parent, File.basename(src)))
          end
        end

        copied += pending.length
      end

      copied
    end

    # Recursively hardlink all files from src_dir into dst_dir.
    # Directory structure is recreated; files are hardlinked.
    def hardlink_tree(src_dir, dst_dir)
      src_dir = File.expand_path(src_dir.to_s)
      dst_dir = File.expand_path(dst_dir.to_s)
      raise Errno::ENOENT, src_dir unless Dir.exist?(src_dir)
      mkdir_p(dst_dir)

      queue = [[src_dir, dst_dir]]
      until queue.empty?
        src_root, dst_root = queue.shift

        Dir.each_child(src_root) do |entry|
          src_path = File.join(src_root, entry)
          dst_path = File.join(dst_root, entry)

          # Guard against recursive copy when destination is nested under source.
          next if dst_dir == src_path || dst_dir.start_with?("#{src_path}/")

          stat = File.lstat(src_path)

          if stat.directory?
            mkdir_p(dst_path)
            queue << [src_path, dst_path]
            next
          end

          mkdir_p(File.dirname(dst_path))
          # Another worker may have already materialized this file.
          next if File.exist?(dst_path)

          begin
            File.link(src_path, dst_path)
          rescue Errno::EEXIST
            # Lost a race to another concurrent linker; destination is valid.
            next
          rescue SystemCallError
            # TOCTOU guard: destination may have appeared after File.link failed.
            next if File.exist?(dst_path)

            begin
              clonefile(src_path, dst_path)
            rescue StandardError
              # If a concurrent worker created destination in the meantime,
              # treat this as success; otherwise bubble up.
              next if File.exist?(dst_path)
              raise
            end
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
