# frozen_string_literal: true

require_relative "../test_helper"
require "scint/lockfile/writer"
require "scint/lockfile/parser"

class LockfileWriterTest < Minitest::Test
  def test_writer_outputs_all_sections_and_sorted_specs
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

    data = Scint::Lockfile::LockfileData.new(
      specs: [
        {
          name: "rack",
          version: "2.2.8",
          platform: "ruby",
          source: "https://rubygems.org/",
          dependencies: [{ name: "base64", version_reqs: [">= 0"] }],
        },
        {
          name: "nio4r",
          version: "2.5.9",
          platform: "x86_64-linux",
          source: "https://rubygems.org/",
          dependencies: [],
        },
      ],
      dependencies: [
        { name: "rack", version_reqs: ["~> 2.2"], pinned: true },
        { name: "nio4r", version_reqs: [">= 2.5"] },
      ],
      platforms: ["ruby", "x86_64-linux"],
      sources: [source],
      bundler_version: "0.1.0",
      ruby_version: "ruby 3.3.0",
      checksums: {
        "rack-2.2.8" => ["sha256=aaa"],
        "nio4r-2.5.9-x86_64-linux" => ["sha256=bbb"],
      },
    )

    out = Scint::Lockfile::Writer.write(data)

    assert_includes out, "GEM\n"
    assert_includes out, "  remote: https://rubygems.org/"
    assert_includes out, "    nio4r (2.5.9-x86_64-linux)"
    assert_includes out, "    rack (2.2.8)"
    assert_includes out, "      base64"

    assert_includes out, "PLATFORMS\n  ruby\n  x86_64-linux"
    assert_includes out, "DEPENDENCIES\n  nio4r (>= 2.5)\n  rack (~> 2.2)!"
    assert_includes out, "CHECKSUMS"
    assert_includes out, "RUBY VERSION\n   ruby 3.3.0"
    assert_includes out, "BUNDLED WITH\n   0.1.0"
  end

  def test_writer_output_is_parseable_for_core_sections
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])
    data = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8", platform: "ruby", source: "https://rubygems.org/", dependencies: [] }],
      dependencies: [{ name: "rack", version_reqs: [">= 0"], pinned: false }],
      platforms: ["ruby"],
      sources: [source],
      bundler_version: "0.1.0",
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)
    parsed = Scint::Lockfile::Parser.parse(out)

    assert_equal ["rack"], parsed.dependencies.keys
    assert_equal "rack", parsed.specs.first[:name]
    assert_equal "2.2.8", parsed.specs.first[:version]
  end

  def test_writer_with_object_specs_and_deps
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

    # Use Struct objects instead of hashes for specs/deps
    spec_obj = Struct.new(:name, :version, :platform, :dependencies, :source, keyword_init: true)
    dep_obj = Struct.new(:name, :version_reqs, :pinned, keyword_init: true)
    spec_dep_obj = Struct.new(:name, :version_reqs, keyword_init: true)

    s = spec_obj.new(
      name: "puma",
      version: "6.0.0",
      platform: "ruby",
      source: "https://rubygems.org/",
      dependencies: [spec_dep_obj.new(name: "nio4r", version_reqs: ["~> 2.0"])],
    )

    d = dep_obj.new(name: "puma", version_reqs: ["~> 6.0"], pinned: false)

    data = Scint::Lockfile::LockfileData.new(
      specs: [s],
      dependencies: [d],
      platforms: ["ruby"],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)

    assert_includes out, "    puma (6.0.0)"
    assert_includes out, "      nio4r (~> 2.0)"
    assert_includes out, "  puma (~> 6.0)"
  end

  def test_writer_source_fallback_equality_match
    # Create a source object that does not respond to :remotes or :uri
    # so the source matching falls through to `source == spec_src` (line 50)
    custom_source = Object.new
    custom_source.define_singleton_method(:to_lock) do
      "CUSTOM\n  remote: custom\n  specs:\n"
    end
    custom_source.define_singleton_method(:to_s) { "custom-source" }

    spec = {
      name: "mygem",
      version: "1.0.0",
      platform: "ruby",
      source: custom_source,  # spec_src == source
      dependencies: [],
    }

    data = Scint::Lockfile::LockfileData.new(
      specs: [spec],
      dependencies: [],
      platforms: ["ruby"],
      sources: [custom_source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)
    assert_includes out, "CUSTOM\n"
    assert_includes out, "    mygem (1.0.0)"
  end

  def test_writer_with_hash_dependencies_input
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

    data = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8", platform: "ruby", source: "https://rubygems.org/", dependencies: [] }],
      dependencies: { "rack" => { name: "rack", version_reqs: [">= 0"], pinned: false } },
      platforms: ["ruby"],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)

    assert_includes out, "DEPENDENCIES\n  rack\n"
  end

  def test_writer_checksums_with_empty_values
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

    data = Scint::Lockfile::LockfileData.new(
      specs: [{ name: "rack", version: "2.2.8", platform: "ruby", source: "https://rubygems.org/", dependencies: [] }],
      dependencies: [],
      platforms: ["ruby"],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: { "rack-2.2.8" => [] },
    )

    out = Scint::Lockfile::Writer.write(data)

    assert_includes out, "CHECKSUMS\n  rack (2.2.8)\n"
    refute_match(/rack \(2\.2\.8\) /, out)
  end

  def test_writer_spec_with_source_object
    source = Scint::Source::Rubygems.new(remotes: ["https://rubygems.org/"])

    # spec that uses a respond_to?(:uri) object
    spec_source = Struct.new(:uri).new("https://rubygems.org/")
    spec = Struct.new(:name, :version, :platform, :dependencies, :source, keyword_init: true).new(
      name: "rack",
      version: "2.2.8",
      platform: "ruby",
      source: spec_source,
      dependencies: [],
    )

    data = Scint::Lockfile::LockfileData.new(
      specs: [spec],
      dependencies: [],
      platforms: ["ruby"],
      sources: [source],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)
    assert_includes out, "    rack (2.2.8)"
  end

  def test_writer_matches_git_sources_when_spec_uri_omits_dot_git
    git_a = Scint::Source::Git.new(uri: "https://github.com/acme/a.git", revision: "aaa")
    git_b = Scint::Source::Git.new(uri: "https://github.com/acme/b.git", revision: "bbb")

    data = Scint::Lockfile::LockfileData.new(
      specs: [
        { name: "a", version: "1.0.0", platform: "ruby", source: "https://github.com/acme/a", dependencies: [] },
        { name: "b", version: "1.0.0", platform: "ruby", source: "https://github.com/acme/b", dependencies: [] },
      ],
      dependencies: [],
      platforms: ["ruby"],
      sources: [git_a, git_b],
      bundler_version: nil,
      ruby_version: nil,
      checksums: nil,
    )

    out = Scint::Lockfile::Writer.write(data)
    parsed = Scint::Lockfile::Parser.parse(out)

    a_spec = parsed.specs.find { |spec| spec[:name] == "a" }
    b_spec = parsed.specs.find { |spec| spec[:name] == "b" }

    assert_equal "https://github.com/acme/a.git", a_spec[:source].uri
    assert_equal "https://github.com/acme/b.git", b_spec[:source].uri
  end
end
