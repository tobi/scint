# frozen_string_literal: true

require_relative "test_helper"
require "bundler2/fs"
require "bundler2/platform"

class FSTest < Minitest::Test
  def setup
    Bundler2::FS.instance_variable_set(:@mkdir_cache, {})
  end

  def test_mkdir_p_is_memoized
    with_tmpdir do |dir|
      target = File.join(dir, "a", "b")
      calls = 0
      original = FileUtils.method(:mkdir_p)

      FileUtils.stub(:mkdir_p, ->(path) { calls += 1; original.call(path) }) do
        Bundler2::FS.mkdir_p(target)
        Bundler2::FS.mkdir_p(target)
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

      Bundler2::Platform.stub(:macos?, false) do
        File.stub(:link, ->(_s, _d) { raise Errno::EXDEV }) do
          Bundler2::FS.clonefile(src, dst)
        end
      end

      assert_equal "hello", File.read(dst)
      refute_equal File.stat(src).ino, File.stat(dst).ino
    end
  end

  def test_hardlink_tree_creates_hardlinks
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(File.join(src, "nested"))
      File.binwrite(File.join(src, "nested", "a.bin"), "abc")

      Bundler2::FS.hardlink_tree(src, dst)

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
        Bundler2::FS.hardlink_tree(src, dst)
      end

      copied = File.join(dst, "file.txt")
      assert_equal "copied", File.read(copied)
      refute_equal File.stat(File.join(src, "file.txt")).ino, File.stat(copied).ino
    end
  end

  def test_hardlink_tree_raises_when_source_missing
    with_tmpdir do |dir|
      src = File.join(dir, "missing")
      dst = File.join(dir, "dst")

      assert_raises(Errno::ENOENT) do
        Bundler2::FS.hardlink_tree(src, dst)
      end
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
        Bundler2::FS.atomic_move(src, dst)
      end

      assert_equal "x", File.binread(dst)
      refute File.exist?(src)
    end
  end

  def test_with_tempdir_cleans_up_on_error
    captured = nil

    assert_raises(RuntimeError) do
      Bundler2::FS.with_tempdir("bundler2-fs") do |dir|
        captured = dir
        raise "boom"
      end
    end

    refute File.exist?(captured)
  end

  def test_atomic_write_replaces_file_contents
    with_tmpdir do |dir|
      path = File.join(dir, "out.txt")

      Bundler2::FS.atomic_write(path, "v1")
      Bundler2::FS.atomic_write(path, "v2")

      assert_equal "v2", File.read(path)
    end
  end
end
