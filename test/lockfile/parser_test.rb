# frozen_string_literal: true

require_relative "../test_helper"
require "scint/lockfile/parser"

class LockfileParserTest < Minitest::Test
  def test_parse_full_lockfile
    contents = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rack (2.2.8)
            base64

      GIT
        remote: https://github.com/acme/lib.git
        revision: abc123
        branch: main
        specs:
          acme-lib (1.0.0)

      PATH
        remote: vendor/gems/local
        specs:
          localgem (0.1.0)

      PLATFORMS
        ruby
        x86_64-linux

      DEPENDENCIES
        rack (~> 2.2)!
        acme-lib

      CHECKSUMS
        rack (2.2.8) sha256=aaa,sha256=bbb
        nio4r (2.5.9-x86_64-linux) sha256=ccc

      RUBY VERSION
        ruby 3.3.0p0

      BUNDLED WITH
         2.5.5
    LOCK

    lock = Scint::Lockfile::Parser.parse(contents)

    assert_equal 3, lock.sources.size
    assert_equal Scint::Source::Rubygems, lock.sources[0].class
    assert_equal Scint::Source::Git, lock.sources[1].class
    assert_equal Scint::Source::Path, lock.sources[2].class

    rack = lock.specs.find { |s| s[:name] == "rack" }
    assert_equal "2.2.8", rack[:version]
    assert_equal "ruby", rack[:platform]
    assert_equal [{ name: "base64", version_reqs: [">= 0"] }], rack[:dependencies]

    dep = lock.dependencies.fetch("rack")
    assert_equal ["~> 2.2"], dep[:version_reqs]
    assert_equal true, dep[:pinned]

    assert_includes lock.platforms, "ruby"
    assert_includes lock.platforms, "x86_64-linux"
    assert_equal "ruby 3.3.0p0", lock.ruby_version
    assert_equal "2.5.5", lock.bundler_version

    assert_equal ["sha256=aaa", "sha256=bbb"], lock.checksums["rack-2.2.8"]
    assert_equal ["sha256=ccc"], lock.checksums["nio4r-2.5.9-x86_64-linux"]
  end

  def test_parse_rejects_merge_conflicts
    contents = <<~LOCK
      GEM
      <<<<<<< HEAD
      =======
      >>>>>>> other
    LOCK

    assert_raises(Scint::LockfileError) { Scint::Lockfile::Parser.parse(contents) }
  end

  def test_parse_ignores_unknown_sections
    contents = <<~LOCK
      UNKNOWN
        hello

      DEPENDENCIES
        rack
    LOCK

    lock = Scint::Lockfile::Parser.parse(contents)
    assert_equal ["rack"], lock.dependencies.keys
  end

  def test_parse_source_with_multiple_remotes
    contents = <<~LOCK
      GEM
        remote: https://rubygems.org/
        remote: https://gems.example.com/
        specs:
          rack (2.2.8)

      DEPENDENCIES
        rack
    LOCK

    lock = Scint::Lockfile::Parser.parse(contents)
    source = lock.sources.first
    assert_instance_of Scint::Source::Rubygems, source
    assert_includes source.remotes, "https://rubygems.org/"
    assert_includes source.remotes, "https://gems.example.com/"
  end

  def test_parse_checksum_without_checksum_string
    contents = <<~LOCK
      CHECKSUMS
        rack (2.2.8)
    LOCK

    lock = Scint::Lockfile::Parser.parse(contents)
    assert_equal [], lock.checksums["rack-2.2.8"]
  end

  def test_parse_path_source
    contents = <<~LOCK
      PATH
        remote: vendor/mygem
        specs:
          mygem (0.1.0)

      DEPENDENCIES
        mygem
    LOCK

    lock = Scint::Lockfile::Parser.parse(contents)
    source = lock.sources.first
    assert_instance_of Scint::Source::Path, source
  end
end
