# frozen_string_literal: true

require_relative "../test_helper"
require "scint/source/rubygems"
require "scint/source/git"
require "scint/source/path"

class SourceTypesTest < Minitest::Test
  # ========== Base class abstract methods ==========

  def test_base_name_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.name }
  end

  def test_base_uri_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.uri }
  end

  def test_base_specs_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.specs }
  end

  def test_base_fetch_spec_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.fetch_spec("rack", "3.0.0") }
  end

  def test_base_cache_slug_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.cache_slug }
  end

  def test_base_to_lock_raises_not_implemented
    base = Scint::Source::Base.new
    assert_raises(NotImplementedError) { base.to_lock }
  end

  def test_base_to_s_returns_string_with_class_name
    # to_s calls uri which raises, so test it on a subclass
    source = Scint::Source::Path.new(path: "/some/path")
    result = source.to_s
    assert_kind_of String, result
    assert_includes result, "path"
  end

  def test_base_to_s_default_implementation
    # Call Base#to_s directly via unbound method on a Path source
    base_to_s = Scint::Source::Base.instance_method(:to_s)
    source = Scint::Source::Path.new(path: "/some/path")
    result = base_to_s.bind(source).call
    assert_includes result, "Path"
    assert_includes result, "/some/path"
  end

  def test_base_equality_delegates_to_eql
    source_a = Scint::Source::Path.new(path: "/some/path")
    source_b = Scint::Source::Path.new(path: "/some/path")
    # == delegates to eql?
    assert_equal source_a, source_b
    assert source_a == source_b
    assert source_a.eql?(source_b)
  end

  def test_base_equality_returns_false_for_different_sources
    source_a = Scint::Source::Path.new(path: "/path/a")
    source_b = Scint::Source::Path.new(path: "/path/b")
    refute_equal source_a, source_b
  end

  # ========== Rubygems source ==========

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

  def test_rubygems_specs_returns_empty_array
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    assert_equal [], source.specs
  end

  def test_rubygems_fetch_spec_returns_nil
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    assert_nil source.fetch_spec("rack", "3.0.0")
    assert_nil source.fetch_spec("rack", "3.0.0", "ruby")
  end

  def test_rubygems_eql_with_same_remotes
    a = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    b = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    assert a.eql?(b)
    assert_equal a, b
  end

  def test_rubygems_not_eql_with_different_remotes
    a = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    b = Scint::Source::Rubygems.new(remotes: ["https://other.example.com"])
    refute a.eql?(b)
    refute_equal a, b
  end

  def test_rubygems_to_s
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org", "https://gems.example.com"])
    result = source.to_s
    assert_includes result, "rubygems"
    assert_includes result, "https://rubygems.org/"
    assert_includes result, "https://gems.example.com/"
  end

  def test_rubygems_name
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org"])
    assert_equal "rubygems", source.name
  end

  # ========== Git source ==========

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

  def test_git_specs_returns_empty_array
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git")
    assert_equal [], source.specs
  end

  def test_git_fetch_spec_returns_nil
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git")
    assert_nil source.fetch_spec("project", "1.0.0")
    assert_nil source.fetch_spec("project", "1.0.0", "ruby")
  end

  def test_git_to_s_with_tag
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", tag: "v1.0")
    result = source.to_s
    assert_includes result, "git: https://github.com/acme/project.git"
    assert_includes result, "v1.0"
  end

  def test_git_to_s_with_branch
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", branch: "develop")
    result = source.to_s
    assert_includes result, "git: https://github.com/acme/project.git"
    assert_includes result, "develop"
  end

  def test_git_to_s_with_ref
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", ref: "abc123")
    result = source.to_s
    assert_includes result, "git: https://github.com/acme/project.git"
    assert_includes result, "abc123"
  end

  def test_git_to_s_without_ref
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git")
    result = source.to_s
    assert_equal "git: https://github.com/acme/project.git", result
  end

  def test_git_to_s_prefers_tag_over_branch
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", tag: "v2.0", branch: "main")
    result = source.to_s
    # tag is checked first in: tag || branch || ref
    assert_includes result, "v2.0"
  end

  def test_git_from_lock
    source = Scint::Source::Git.from_lock(
      "remote" => "https://github.com/acme/project.git",
      "revision" => "abc123",
      "branch" => "main",
      "tag" => nil,
      "submodules" => nil,
      "glob" => nil,
      "name" => nil,
    )
    assert_equal "https://github.com/acme/project.git", source.uri
    assert_equal "abc123", source.revision
    assert_equal "main", source.branch
    assert_equal "project", source.name
  end

  def test_git_name_with_explicit_name
    source = Scint::Source::Git.new(uri: "https://github.com/acme/project.git", name: "custom")
    assert_equal "custom", source.name
  end

  # ========== Path source ==========

  def test_path_source_uses_expanded_path_for_equality
    with_tmpdir do |dir|
      a = Scint::Source::Path.new(path: File.join(dir, "vendor", "..", "vendor", "gems"))
      b = Scint::Source::Path.new(path: File.join(dir, "vendor", "gems"))

      assert_equal a, b
      assert_equal a.hash, b.hash
      assert_includes a.to_lock, "PATH\n"
    end
  end

  def test_path_name_from_basename
    source = Scint::Source::Path.new(path: "/home/user/projects/my_gem")
    assert_equal "my_gem", source.name
  end

  def test_path_name_explicit
    source = Scint::Source::Path.new(path: "/home/user/projects/my_gem", name: "custom_name")
    assert_equal "custom_name", source.name
  end

  def test_path_uri_returns_path
    source = Scint::Source::Path.new(path: "/some/path/to/gem")
    assert_equal "/some/path/to/gem", source.uri
  end

  def test_path_specs_returns_empty_array
    source = Scint::Source::Path.new(path: "/some/path")
    assert_equal [], source.specs
  end

  def test_path_fetch_spec_returns_nil
    source = Scint::Source::Path.new(path: "/some/path")
    assert_nil source.fetch_spec("mygem", "1.0.0")
    assert_nil source.fetch_spec("mygem", "1.0.0", "ruby")
  end

  def test_path_cache_slug_returns_name
    source = Scint::Source::Path.new(path: "/some/path/my_gem")
    assert_equal "my_gem", source.cache_slug
  end

  def test_path_to_s
    source = Scint::Source::Path.new(path: "/some/path/my_gem")
    assert_equal "path: /some/path/my_gem", source.to_s
  end

  def test_path_to_lock_with_default_glob
    source = Scint::Source::Path.new(path: "/some/path")
    lock = source.to_lock
    assert_includes lock, "PATH\n"
    assert_includes lock, "  remote: /some/path\n"
    assert_includes lock, "  specs:\n"
    refute_includes lock, "  glob:"
  end

  def test_path_to_lock_with_custom_glob
    source = Scint::Source::Path.new(path: "/some/path", glob: "*.gemspec")
    lock = source.to_lock
    assert_includes lock, "  glob: *.gemspec\n"
  end

  def test_path_from_lock
    source = Scint::Source::Path.from_lock(
      "remote" => "/some/path/my_gem",
      "glob" => nil,
      "name" => "custom",
      "version" => "1.0.0",
    )
    assert_equal "/some/path/my_gem", source.uri
    assert_equal "custom", source.name
  end
end
