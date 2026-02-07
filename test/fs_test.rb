# frozen_string_literal: true

require_relative "test_helper"
require "scint/fs"
require "scint/platform"

class FSTest < Minitest::Test
  def setup
    Scint::FS.instance_variable_set(:@mkdir_cache, {})
  end

  def test_mkdir_p_is_memoized
    with_tmpdir do |dir|
      target = File.join(dir, "a", "b")
      calls = 0
      original = FileUtils.method(:mkdir_p)

      FileUtils.stub(:mkdir_p, ->(path) { calls += 1; original.call(path) }) do
        Scint::FS.mkdir_p(target)
        Scint::FS.mkdir_p(target)
      end

      assert Dir.exist?(target)
      assert_equal 1, calls
    end
  end

  def test_clonefile_falls_back_to_copy_when_hardlink_fails
    with_tmpdir do |dir|
      src = File.join(dir, "src.txt")
      dst = File.join(dir, "dst.txt")
      File.write(src, "hello")

      Scint::Platform.stub(:macos?, false) do
        Scint::Platform.stub(:linux?, false) do
          File.stub(:link, ->(_s, _d) { raise Errno::EXDEV }) do
            Scint::FS.clonefile(src, dst)
          end
        end
      end

      assert_equal "hello", File.read(dst)
      refute_equal File.stat(src).ino, File.stat(dst).ino
    end
  end

  def test_clonefile_uses_reflink_on_linux
    with_tmpdir do |dir|
      src = File.join(dir, "src.txt")
      dst = File.join(dir, "dst.txt")
      File.write(src, "hello")

      called = false
      Scint::Platform.stub(:macos?, false) do
        Scint::Platform.stub(:linux?, true) do
          Scint::FS.stub(:system, lambda { |*args|
            called = true
            assert_equal "cp", args[0]
            assert_equal "--reflink=always", args[1]
            assert_equal src, args[2]
            assert_equal dst, args[3]
            assert_equal({ [:out, :err] => File::NULL }, args[4])
            FileUtils.cp(src, dst)
            true
          }) do
            Scint::FS.clonefile(src, dst)
          end
        end
      end

      assert called
      assert_equal "hello", File.read(dst)
    end
  end

  def test_hardlink_tree_creates_hardlinks
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(File.join(src, "nested"))
      File.binwrite(File.join(src, "nested", "a.bin"), "abc")

      Scint::FS.hardlink_tree(src, dst)

      linked = File.join(dst, "nested", "a.bin")
      assert File.exist?(linked)
      assert_hardlinked(File.join(src, "nested", "a.bin"), linked)
    end
  end

  def test_hardlink_tree_falls_back_to_copy
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.binwrite(File.join(src, "file.txt"), "copied")

      File.stub(:link, ->(_s, _d) { raise Errno::EXDEV }) do
        Scint::FS.hardlink_tree(src, dst)
      end

      copied = File.join(dst, "file.txt")
      assert_equal "copied", File.read(copied)
      refute_equal File.stat(File.join(src, "file.txt")).ino, File.stat(copied).ino
    end
  end

  def test_hardlink_tree_is_idempotent_when_destination_exists
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.binwrite(File.join(src, "file.txt"), "copied")

      Scint::FS.hardlink_tree(src, dst)
      Scint::FS.hardlink_tree(src, dst)

      copied = File.join(dst, "file.txt")
      assert File.exist?(copied)
      assert_equal "copied", File.read(copied)
    end
  end

  def test_hardlink_tree_raises_when_source_missing
    with_tmpdir do |dir|
      src = File.join(dir, "missing")
      dst = File.join(dir, "dst")

      assert_raises(Errno::ENOENT) do
        Scint::FS.hardlink_tree(src, dst)
      end
    end
  end

  def test_clone_tree_uses_cp_clone_on_macos
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.binwrite(File.join(src, "a.txt"), "a")

      called = false
      Scint::Platform.stub(:macos?, true) do
        Scint::FS.stub(:system, lambda { |*args|
          called = true
          assert_equal "cp", args[0]
          assert_equal "-cR", args[1]
          assert_equal File.join(src, "."), args[2]
          assert_equal dst, args[3]
          assert_equal({ [:out, :err] => File::NULL }, args[4])
          FileUtils.mkdir_p(dst)
          FileUtils.cp_r(File.join(src, "."), dst)
          true
        }) do
          Scint::FS.clone_tree(src, dst)
        end
      end

      assert called
      assert_equal "a", File.binread(File.join(dst, "a.txt"))
    end
  end

  def test_clone_tree_falls_back_to_hardlink_tree
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.binwrite(File.join(src, "a.txt"), "a")

      fallback_called = false
      Scint::Platform.stub(:macos?, true) do
        Scint::FS.stub(:system, ->(*_args) { false }) do
          Scint::FS.stub(:hardlink_tree, lambda { |s, d|
            fallback_called = true
            FileUtils.mkdir_p(d)
            FileUtils.cp_r(File.join(s, "."), d)
          }) do
            Scint::FS.clone_tree(src, dst)
          end
        end
      end

      assert fallback_called
      assert_equal "a", File.binread(File.join(dst, "a.txt"))
    end
  end

  def test_clone_tree_uses_reflink_on_linux
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.binwrite(File.join(src, "a.txt"), "a")

      called = false
      Scint::Platform.stub(:macos?, false) do
        Scint::Platform.stub(:linux?, true) do
          Scint::FS.stub(:system, lambda { |*args|
            called = true
            assert_equal "cp", args[0]
            assert_equal "--reflink=always", args[1]
            assert_equal "-R", args[2]
            assert_equal File.join(src, "."), args[3]
            assert_equal dst, args[4]
            assert_equal({ [:out, :err] => File::NULL }, args[5])
            FileUtils.mkdir_p(dst)
            FileUtils.cp_r(File.join(src, "."), dst)
            true
          }) do
            Scint::FS.clone_tree(src, dst)
          end
        end
      end

      assert called
      assert_equal "a", File.binread(File.join(dst, "a.txt"))
    end
  end

  def test_atomic_move_handles_cross_device_rename
    with_tmpdir do |dir|
      src = File.join(dir, "src.txt")
      dst = File.join(dir, "out", "dst.txt")
      File.binwrite(src, "x")

      calls = 0
      original = File.method(:rename)

      File.stub(:rename, lambda { |a, b|
        calls += 1
        raise Errno::EXDEV if calls == 1

        original.call(a, b)
      }) do
        Scint::FS.atomic_move(src, dst)
      end

      assert_equal "x", File.binread(dst)
      refute File.exist?(src)
    end
  end

  def test_with_tempdir_cleans_up_on_error
    captured = nil

    assert_raises(RuntimeError) do
      Scint::FS.with_tempdir("scint-fs") do |dir|
        captured = dir
        raise "boom"
      end
    end

    refute File.exist?(captured)
  end

  def test_atomic_write_replaces_file_contents
    with_tmpdir do |dir|
      path = File.join(dir, "out.txt")

      Scint::FS.atomic_write(path, "v1")
      Scint::FS.atomic_write(path, "v2")

      assert_equal "v2", File.read(path)
    end
  end

  def test_clonefile_uses_system_cp_on_macos
    with_tmpdir do |dir|
      src = File.join(dir, "src.txt")
      dst = File.join(dir, "dst.txt")
      File.write(src, "clone")

      Scint::Platform.stub(:macos?, true) do
        # Stub system to simulate successful cp -c
        Object.stub(:system, lambda { |*args|
          # Simulate success: just do a regular copy
          FileUtils.cp(src, dst) unless File.exist?(dst)
          true
        }) do
          Scint::FS.clonefile(src, dst)
        end
      end

      assert_equal "clone", File.read(dst)
    end
  end

  def test_atomic_move_handles_cross_device_directory
    with_tmpdir do |dir|
      src_dir = File.join(dir, "src_dir")
      dst_dir = File.join(dir, "dst_dir")
      FileUtils.mkdir_p(src_dir)
      File.write(File.join(src_dir, "file.txt"), "content")

      calls = 0
      original = File.method(:rename)

      File.stub(:rename, lambda { |a, b|
        calls += 1
        raise Errno::EXDEV if calls == 1
        original.call(a, b)
      }) do
        Scint::FS.atomic_move(src_dir, dst_dir)
      end

      assert File.exist?(File.join(dst_dir, "file.txt"))
      assert_equal "content", File.read(File.join(dst_dir, "file.txt"))
      refute File.exist?(src_dir)
    end
  end
end
