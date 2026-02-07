# frozen_string_literal: true

require_relative "../test_helper"
require "scint/gemfile/parser"

class GemfileParserTest < Minitest::Test
  def test_parse_complex_gemfile_dsl
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "vendor", "gems"))

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"

        git_source(:corp) { |repo| "https://git.corp/\#{repo}.git" }

        group :development do
          gem "rake", "~> 13.0", require: false
        end

        platforms :jruby do
          gem "jruby-openssl"
        end

        gem "rack", ">= 2.2"
        gem "mygem", corp: "team/mygem", branch: "main"
        gem "tool", github: "acme/tool"

        path "vendor/gems" do
          gem "localgem"
        end
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |d, h| h[d.name] = d }

      assert_equal [">= 2.2"], deps.fetch("rack").version_reqs
      assert_equal [:development], deps.fetch("rake").groups
      assert_equal [], deps.fetch("rake").require_paths
      assert_equal [:jruby], deps.fetch("jruby-openssl").platforms

      mygem = deps.fetch("mygem")
      assert_equal "https://git.corp/team/mygem.git", mygem.source_options[:git]
      assert_equal "main", mygem.source_options[:branch]

      tool = deps.fetch("tool")
      assert_equal "https://github.com/acme/tool.git", tool.source_options[:git]

      local = deps.fetch("localgem")
      assert_equal File.join(dir, "vendor", "gems"), local.source_options[:path]

      assert_equal [{ type: :rubygems, uri: "https://rubygems.org" }], result.sources
    end
  end

  def test_eval_gemfile_loads_secondary_file
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile.extra"), <<~RUBY)
        gem "rack", ">= 2.2"
      RUBY

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        eval_gemfile "Gemfile.extra"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      assert_equal ["rack"], result.dependencies.map(&:name)
    end
  end

  def test_github_pull_request_shortcut_sets_ref
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "demo", github: "https://github.com/ruby/ruby/pull/123"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://github.com/ruby/ruby.git", dep.source_options[:git]
      assert_equal "refs/pull/123/head", dep.source_options[:ref]
    end
  end

  def test_parse_raises_clear_error_for_undefined_method
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        totally_unknown_helper "x"
      RUBY

      error = assert_raises(Scint::GemfileError) { Scint::Gemfile::Parser.parse(gemfile) }
      assert_includes error.message, "Undefined local variable or method"
    end
  end

  def test_parse_wraps_syntax_errors
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, "gem \"rack\"\nend\n")

      error = assert_raises(Scint::GemfileError) { Scint::Gemfile::Parser.parse(gemfile) }
      assert_includes error.message, "Syntax error"
    end
  end
end
