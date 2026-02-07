# frozen_string_literal: true

require_relative "../test_helper"
require "scint/source/rubygems"
require "scint/source/git"
require "scint/source/path"

class SourceTypesTest < Minitest::Test
  def test_rubygems_normalizes_remotes_and_builds_lock_output
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org", "https://gems.example.com/private/"])
    source.add_remote("https://rubygems.org/")

    assert_equal ["https://rubygems.org/", "https://gems.example.com/private/"], source.remotes
    assert_equal "rubygems.org", source.cache_slug

    lock = source.to_lock
    assert_includes lock, "GEM\n"
    assert_includes lock, "  remote: https://gems.example.com/private/"
    assert_includes lock, "  remote: https://rubygems.org/"
  end

  def test_rubygems_from_lock_preserves_remote_priority
    source = Scint::Source::Rubygems.from_lock("remote" => ["https://second/", "https://first/"])
    assert_equal ["https://first/", "https://second/"], source.remotes
    assert_equal "https://first/", source.uri
  end

  def test_git_source_lock_and_identity
    source = Scint::Source::Git.new(
      uri: "https://github.com/acme/project.git",
      revision: "abc123",
      branch: "main",
      submodules: true,
      glob: "*.gemspec",
    )

    assert_equal "project", source.name
    assert_match(/^project-[0-9a-f]{12}$/, source.cache_slug)

    lock = source.to_lock
    assert_includes lock, "GIT\n"
    assert_includes lock, "  remote: https://github.com/acme/project.git"
    assert_includes lock, "  revision: abc123"
    assert_includes lock, "  branch: main"
    assert_includes lock, "  submodules: true"
    assert_includes lock, "  glob: *.gemspec"

    same = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", branch: "main", submodules: true)
    assert_equal source, same
    assert_equal source.hash, same.hash
  end

  def test_path_source_uses_expanded_path_for_equality
    with_tmpdir do |dir|
      a = Scint::Source::Path.new(path: File.join(dir, "vendor", "..", "vendor", "gems"))
      b = Scint::Source::Path.new(path: File.join(dir, "vendor", "gems"))

      assert_equal a, b
      assert_equal a.hash, b.hash
      assert_includes a.to_lock, "PATH\n"
    end
  end
end
