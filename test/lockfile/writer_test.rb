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
    assert_includes out, "RUBY VERSION\n  ruby 3.3.0"
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
end
