# frozen_string_literal: true

require_relative "../test_helper"
require "scint/gem/extractor"

class ExtractorTest < Minitest::Test
  def test_extract_with_ruby_ignores_path_traversal_entries
    with_tmpdir do |dir|
      extractor = Scint::GemPkg::Extractor.new
      tar_gz = File.join(dir, "data.tar.gz")
      dest = File.join(dir, "dest")

      tar_data = make_tar([
        { type: :file, name: "lib/ok.rb", content: "ok" },
        { type: :file, name: "../../outside.txt", content: "bad" },
      ])
      File.binwrite(tar_gz, gzip(tar_data))

      extractor.stub(:system_tar_available?, false) do
        extractor.extract(tar_gz, dest)
      end

      assert_equal "ok", File.read(File.join(dest, "lib", "ok.rb"))
      refute File.exist?(File.join(dir, "outside.txt"))
    end
  end

  def test_extract_with_ruby_only_creates_safe_symlinks
    with_tmpdir do |dir|
      extractor = Scint::GemPkg::Extractor.new
      tar_gz = File.join(dir, "data.tar.gz")
      dest = File.join(dir, "dest")

      tar_data = make_tar([
        { type: :file, name: "lib/a.rb", content: "ok" },
        { type: :symlink, name: "lib/good_link", target: "a.rb" },
        { type: :symlink, name: "lib/bad_link", target: "../../etc/passwd" },
      ])
      File.binwrite(tar_gz, gzip(tar_data))

      extractor.stub(:system_tar_available?, false) do
        extractor.extract(tar_gz, dest)
      end

      good = File.join(dest, "lib", "good_link")
      bad = File.join(dest, "lib", "bad_link")

      assert File.symlink?(good)
      refute File.exist?(bad)
    end
  end

  def test_system_tar_available_returns_false_if_tar_missing
    extractor = Scint::GemPkg::Extractor.new

    extractor.stub(:system, ->(*_args) { raise Errno::ENOENT }) do
      assert_equal false, extractor.send(:system_tar_available?)
      assert_equal false, extractor.send(:system_tar_available?)
    end
  end

  def test_extract_with_system_tar_falls_back_to_ruby
    with_tmpdir do |dir|
      extractor = Scint::GemPkg::Extractor.new
      tar_gz = File.join(dir, "data.tar.gz")
      dest = File.join(dir, "dest")

      tar_data = make_tar([{ type: :file, name: "lib/from_ruby.rb", content: "ok" }])
      File.binwrite(tar_gz, gzip(tar_data))

      extractor.stub(:system, false) do
        extractor.send(:extract_with_system_tar, tar_gz, dest)
      end

      assert_equal "ok", File.read(File.join(dest, "lib", "from_ruby.rb"))
    end
  end
end
