# frozen_string_literal: true

require_relative "test_helper"
require "scint/spec_utils"

class SpecUtilsTest < Minitest::Test
  def write_minimal_gemspec(path, body)
    File.write(path, <<~RUBY)
      #{body}
      Gem::Specification.new do |s|
        s.name = "demo"
        s.version = "1.2.3"
        s.summary = "demo"
        s.authors = ["test"]
      end
    RUBY
  end

  def test_load_gemspec_falls_back_for_relative_require
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib", "demo"))
      File.write(File.join(dir, "lib", "demo", "version.rb"), <<~RUBY)
        module Demo
          VERSION = "1.2.3"
        end
      RUBY
      gemspec_path = File.join(dir, "demo.gemspec")
      File.write(gemspec_path, <<~RUBY)
        require "./lib/demo/version"
        Gem::Specification.new do |s|
          s.name = "demo"
          s.version = Demo::VERSION
          s.summary = "demo"
          s.authors = ["test"]
        end
      RUBY

      spec = Scint::SpecUtils.load_gemspec(gemspec_path)
      refute_nil spec
      assert_equal "demo", spec.name
      assert_equal Gem::Version.new("1.2.3"), spec.version
    end
  end

  def test_load_gemspec_handles_relative_readme
    with_tmpdir do |dir|
      File.write(File.join(dir, "README"), "demo readme")
      gemspec_path = File.join(dir, "demo.gemspec")
      write_minimal_gemspec(gemspec_path, 'File.read("README")')

      spec = Scint::SpecUtils.load_gemspec(gemspec_path)
      refute_nil spec
      assert_equal "demo", spec.name
    end
  end

  def test_load_gemspec_handles_relative_gemspec_yml
    with_tmpdir do |dir|
      File.write(File.join(dir, "gemspec.yml"), "name: demo")
      gemspec_path = File.join(dir, "demo.gemspec")
      write_minimal_gemspec(gemspec_path, 'File.read("gemspec.yml")')

      spec = Scint::SpecUtils.load_gemspec(gemspec_path)
      refute_nil spec
      assert_equal "demo", spec.name
    end
  end

  def test_load_gemspec_falls_back_when_direct_load_hits_conflicting_chdir
    with_tmpdir do |dir|
      gemspec_path = File.join(dir, "demo.gemspec")
      write_minimal_gemspec(gemspec_path, "")

      Gem::Specification.stub(:load, ->(_path) { raise RuntimeError, "conflicting chdir during another chdir block" }) do
        spec = Scint::SpecUtils.load_gemspec(gemspec_path)
        refute_nil spec
        assert_equal "demo", spec.name
      end
    end
  end

  def test_load_gemspec_falls_back_when_direct_load_cannot_read_cwd
    with_tmpdir do |dir|
      gemspec_path = File.join(dir, "demo.gemspec")
      write_minimal_gemspec(gemspec_path, "")

      first_call = true
      Gem::Specification.stub(:load, lambda { |_path|
        if first_call
          first_call = false
          raise Errno::ENOENT, "Unable to read current working directory"
        end

        nil
      }) do
        spec = Scint::SpecUtils.load_gemspec(gemspec_path)
        refute_nil spec
        assert_equal "demo", spec.name
      end
    end
  end

  def test_load_gemspec_isolate_does_not_mutate_parent_cwd
    with_tmpdir do |dir|
      gemspec_path = File.join(dir, "demo.gemspec")
      write_minimal_gemspec(gemspec_path, 'Dir.chdir("..")')

      original = Dir.pwd
      spec = Scint::SpecUtils.load_gemspec(gemspec_path, isolate: true)
      refute_nil spec
      assert_equal original, Dir.pwd
    end
  end

  def test_load_gemspec_returns_nil_for_non_path_error
    with_tmpdir do |dir|
      gemspec_path = File.join(dir, "broken.gemspec")
      File.write(gemspec_path, <<~RUBY)
        raise "boom"
      RUBY

      assert_nil Scint::SpecUtils.load_gemspec(gemspec_path)
    end
  end
end
