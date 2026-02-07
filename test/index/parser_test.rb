# frozen_string_literal: true

require_relative "../test_helper"
require "scint/index/parser"

class IndexParserTest < Minitest::Test
  def test_parse_names_strips_header
    parser = Scint::Index::Parser.new
    names = parser.parse_names("---\nrack\nrails\n")

    assert_equal %w[rack rails], names
  end

  def test_parse_versions_handles_adds_deletes_and_checksums
    parser = Scint::Index::Parser.new
    versions = parser.parse_versions(<<~DATA)
      ---
      rack 1.0.0,1.1.0 abc
      rack -1.0.0 abc2
      ffi 1.16.0-x86_64-linux def
    DATA

    assert_equal [["rack", "1.1.0"]], versions["rack"]
    assert_equal [["ffi", "1.16.0", "x86_64-linux"]], versions["ffi"]
    assert_equal "abc2", parser.info_checksums["rack"]
    assert_equal "def", parser.info_checksums["ffi"]
  end

  def test_parse_info_parses_deps_requirements_and_platform
    parser = Scint::Index::Parser.new
    lines = parser.parse_info("rack", "2.2.8-x86_64-linux dep1:>=1&<2,dep2|ruby:>=3.1,rubygems:>=3.4\n")

    name, version, platform, deps, reqs = lines.first
    assert_equal "rack", name
    assert_equal "2.2.8", version
    assert_equal "x86_64-linux", platform
    assert_equal({ "dep1" => ">=1, <2", "dep2" => ">= 0" }, deps)
    assert_equal({ "ruby" => ">=3.1", "rubygems" => ">=3.4" }, reqs)
  end

  def test_parse_info_defaults_platform_to_ruby
    parser = Scint::Index::Parser.new
    line = parser.parse_info("rack", "2.2.8\n").first

    assert_equal ["rack", "2.2.8", "ruby", {}, {}], line
  end

  def test_parse_versions_without_checksum
    parser = Scint::Index::Parser.new
    versions = parser.parse_versions("---\nmygem 1.0.0\n")

    assert_equal [["mygem", "1.0.0"]], versions["mygem"]
    assert_equal "", parser.info_checksums["mygem"]
  end

  def test_parse_info_requirement_without_version_constraint
    parser = Scint::Index::Parser.new
    lines = parser.parse_info("rack", "2.0.0 |ruby\n")

    _name, _version, _platform, _deps, reqs = lines.first
    assert_equal({ "ruby" => ">= 0" }, reqs)
  end
end
