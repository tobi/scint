# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/gem/package"

class PackageTest < Minitest::Test
  def test_read_metadata_returns_gemspec
    with_tmpdir do |dir|
      gem_path = File.join(dir, "demo-1.0.0.gem")
      create_fake_gem(
        gem_path,
        name: "demo",
        version: "1.0.0",
        files: { "lib/demo.rb" => "module Demo; end\n" },
      )

      pkg = Bundler2::GemPkg::Package.new
      spec = pkg.read_metadata(gem_path)

      assert_equal "demo", spec.name
      assert_equal Gem::Version.new("1.0.0"), spec.version
    end
  end

  def test_extract_returns_gemspec_and_extracts_data
    with_tmpdir do |dir|
      gem_path = File.join(dir, "demo-1.0.0.gem")
      create_fake_gem(
        gem_path,
        name: "demo",
        version: "1.0.0",
        files: {
          "lib/demo.rb" => "module Demo; end\n",
          "README.md" => "hello",
        },
      )

      pkg = Bundler2::GemPkg::Package.new
      dest = File.join(dir, "out")
      result = pkg.extract(gem_path, dest)

      assert_equal "demo", result[:gemspec].name
      assert_equal dest, result[:extracted_path]
      assert_equal "module Demo; end\n", File.read(File.join(dest, "lib", "demo.rb"))
      assert_equal "hello", File.read(File.join(dest, "README.md"))
      refute File.exist?(File.join(dest, ".data.tar.gz.tmp"))
    end
  end

  def test_extract_raises_when_metadata_missing
    with_tmpdir do |dir|
      gem_path = File.join(dir, "broken.gem")
      data_tar_gz = gzip(make_tar([{ type: :file, name: "lib/x.rb", content: "x" }]))
      File.binwrite(gem_path, make_tar([{ type: :file, name: "data.tar.gz", content: data_tar_gz }]))

      pkg = Bundler2::GemPkg::Package.new
      error = assert_raises(Bundler2::InstallError) { pkg.extract(gem_path, File.join(dir, "out")) }

      assert_includes error.message, "No metadata.gz"
    end
  end
end
