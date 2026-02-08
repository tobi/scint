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

  def test_source_block_form_scopes_gems_to_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"

        source "https://private.example.com" do
          gem "private-gem"
        end

        gem "public-gem"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |d, h| h[d.name] = d }

      private_gem = deps.fetch("private-gem")
      assert_equal "https://private.example.com", private_gem.source_options[:source]

      public_gem = deps.fetch("public-gem")
      refute public_gem.source_options.key?(:source), "public-gem should not have a scoped source"

      # Both sources should be registered
      uris = result.sources.map { |s| s[:uri] }
      assert_includes uris, "https://rubygems.org"
      assert_includes uris, "https://private.example.com"
    end
  end

  def test_git_block_form_scopes_gems_to_git_repo
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"

        git "https://github.com/rails/rails.git", branch: "main" do
          gem "activesupport"
          gem "activerecord"
        end

        gem "rack"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |d, h| h[d.name] = d }

      as = deps.fetch("activesupport")
      assert_equal "https://github.com/rails/rails.git", as.source_options[:git]
      assert_equal "main", as.source_options[:branch]

      ar = deps.fetch("activerecord")
      assert_equal "https://github.com/rails/rails.git", ar.source_options[:git]
      assert_equal "main", ar.source_options[:branch]

      rack = deps.fetch("rack")
      refute rack.source_options.key?(:git), "rack should not have git source after git block ends"
    end
  end

  def test_gemspec_directive
    with_tmpdir do |dir|
      # Create a .gemspec file in the directory
      File.write(File.join(dir, "mygem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gemspec
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |d, h| h[d.name] = d }

      mygem = deps.fetch("mygem")
      assert_equal dir, mygem.source_options[:path]
    end
  end

  def test_gemspec_with_name_option
    with_tmpdir do |dir|
      File.write(File.join(dir, "mygem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      File.write(File.join(dir, "othergem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "othergem"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gemspec name: "mygem"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      names = result.dependencies.map(&:name)

      assert_includes names, "mygem"
      refute_includes names, "othergem"
    end
  end

  def test_gemspec_with_path_option
    with_tmpdir do |dir|
      subdir = File.join(dir, "subdir")
      FileUtils.mkdir_p(subdir)

      File.write(File.join(subdir, "subgem.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "subgem"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gemspec path: "subdir"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "subgem", dep.name
      assert_equal subdir, dep.source_options[:path]
    end
  end

  def test_ruby_version_setting
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        ruby "3.2.0"
        gem "rack"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)

      assert_equal "3.2.0", result.ruby_version
    end
  end

  def test_ruby_version_setting_with_multiple_constraints
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        ruby ">= 3.2.0", "< 4.1.0"
        gem "rack"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      assert_equal ">= 3.2.0, < 4.1.0", result.ruby_version
    end
  end

  def test_gemspec_default_glob_includes_nested_component_gemspecs
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "components"))

      File.write(File.join(dir, "root.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "root"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      File.write(File.join(dir, "components", "child.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "child"
          s.version = "1.0.0"
          s.authors = ["test"]
          s.summary = "test"
        end
      RUBY

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gemspec
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |dep, out| out[dep.name] = dep }

      assert_includes deps.keys, "root"
      assert_includes deps.keys, "child"
      assert_equal dir, deps.fetch("root").source_options[:path]
      assert_equal File.join(dir, "components"), deps.fetch("child").source_options[:path]
    end
  end

  def test_plugin_method_is_silently_ignored
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        plugin "bundler-audit"
        gem "rack"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      names = result.dependencies.map(&:name)

      assert_equal ["rack"], names
    end
  end

  def test_gem_with_require_false
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "debug", require: false
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "debug", dep.name
      assert_equal [], dep.require_paths
    end
  end

  def test_gem_with_require_multiple_paths
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "aws-sdk", require: ["aws-sdk-s3", "aws-sdk-ec2"]
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "aws-sdk", dep.name
      assert_equal ["aws-sdk-s3", "aws-sdk-ec2"], dep.require_paths
    end
  end

  def test_nested_group_and_platform_combination
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"

        group :development do
          platforms :ruby do
            gem "byebug"
          end

          gem "pry"
        end

        gem "rack"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      deps = result.dependencies.each_with_object({}) { |d, h| h[d.name] = d }

      byebug = deps.fetch("byebug")
      assert_equal [:development], byebug.groups
      assert_equal [:ruby], byebug.platforms

      pry = deps.fetch("pry")
      assert_equal [:development], pry.groups
      assert_equal [], pry.platforms, "pry should have no platform constraint outside platforms block"

      rack = deps.fetch("rack")
      assert_equal [:default], rack.groups
      assert_equal [], rack.platforms
    end
  end

  def test_gem_with_inline_group_option
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "rspec", group: :test
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "rspec", dep.name
      assert_equal [:test], dep.groups
    end
  end

  def test_gem_with_inline_platform_option
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "wdm", platforms: [:mingw, :mswin]
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "wdm", dep.name
      assert_equal [:mingw, :mswin], dep.platforms
    end
  end

  def test_install_if_with_truthy_condition_evaluates_block
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        group :test do
          install_if -> { true } do
            gem "rack"
          end
        end
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "rack", dep.name
      assert_equal [:test], dep.groups
    end
  end

  def test_install_if_with_false_condition_skips_block
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        install_if -> { false } do
          gem "rack"
        end
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      assert_empty result.dependencies
    end
  end

  def test_install_if_requires_a_block
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        install_if true
      RUBY

      error = assert_raises(Scint::GemfileError) { Scint::Gemfile::Parser.parse(gemfile) }
      assert_includes error.message, "install_if requires a block"
    end
  end

  def test_gem_with_explicit_source_option
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "private", source: "https://gems.example.com"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "private", dep.name
      assert_equal "https://gems.example.com", dep.source_options[:source]
    end
  end

  def test_gem_with_git_option_and_tag
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "rails", git: "https://github.com/rails/rails.git", tag: "v7.0.0"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "rails", dep.name
      assert_equal "https://github.com/rails/rails.git", dep.source_options[:git]
      assert_equal "v7.0.0", dep.source_options[:tag]
    end
  end

  def test_gem_with_path_option
    with_tmpdir do |dir|
      subdir = File.join(dir, "local_gems", "mygem")
      FileUtils.mkdir_p(subdir)

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "mygem", path: "local_gems/mygem"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first

      assert_equal "mygem", dep.name
      assert_equal subdir, dep.source_options[:path]
    end
  end

  def test_github_shorthand_with_user_only
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "pry", github: "pry"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://github.com/pry/pry.git", dep.source_options[:git]
    end
  end

  def test_git_source_returning_hash_with_pr_url
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "mylib", github: "https://github.com/owner/repo/pull/42"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://github.com/owner/repo.git", dep.source_options[:git]
      assert_equal "refs/pull/42/head", dep.source_options[:ref]
    end
  end

  def test_path_block_with_absolute_path
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        path "/absolute/vendor" do
          gem "vendor_gem"
        end
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "/absolute/vendor", dep.source_options[:path]
    end
  end

  def test_eval_gemfile_with_absolute_path
    with_tmpdir do |dir|
      extra = File.join(dir, "extra.rb")
      File.write(extra, 'gem "extra_gem"')

      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        eval_gemfile "#{extra}"
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      assert_equal ["extra_gem"], result.dependencies.map(&:name)
    end
  end

  def test_respond_to_missing_returns_false
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, 'source "https://rubygems.org"')

      parser = Scint::Gemfile::Parser.new(gemfile)
      assert_equal false, parser.respond_to?(:nonexistent_method)
    end
  end

  def test_gist_git_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "snippet", gist: "abc123"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://gist.github.com/abc123.git", dep.source_options[:git]
    end
  end

  def test_bitbucket_git_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "bbgem", bitbucket: "user/repo"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://user@bitbucket.org/user/repo.git", dep.source_options[:git]
    end
  end

  def test_bitbucket_git_source_with_user_only
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        gem "bbgem", bitbucket: "user"
      RUBY

      dep = Scint::Gemfile::Parser.parse(gemfile).dependencies.first
      assert_equal "https://user@bitbucket.org/user/user.git", dep.source_options[:git]
    end
  end

  def test_platforms_declaration
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, <<~RUBY)
        source "https://rubygems.org"
        # Gemfile doesn't have a "platforms" declaration section,
        # but we test the platform method for scoping
        platform :ruby do
          gem "byebug"
        end
      RUBY

      result = Scint::Gemfile::Parser.parse(gemfile)
      dep = result.dependencies.first
      assert_equal [:ruby], dep.platforms
    end
  end

  # Tests for the explicit github: option handling (lines 112-122 of parser.rb).
  # When no :github git_source callback is registered, the inline github: option
  # code path handles PR URLs and shorthand repo names directly.

  def test_github_pr_url_via_inline_option_without_git_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, 'source "https://rubygems.org"')

      parser = Scint::Gemfile::Parser.new(gemfile)
      # Remove the default :github git_source so the inline option code path runs
      parser.instance_variable_get(:@git_sources).delete(:github)

      # Call gem directly with a PR URL
      parser.send(:gem, "demo", github: "https://github.com/user/repo/pull/123")
      dep = parser.parsed_dependencies.last

      assert_equal "https://github.com/user/repo.git", dep.source_options[:git]
      assert_equal "refs/pull/123/head", dep.source_options[:ref]
    end
  end

  def test_github_shorthand_repo_via_inline_option_without_git_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, 'source "https://rubygems.org"')

      parser = Scint::Gemfile::Parser.new(gemfile)
      # Remove the default :github git_source so the inline option code path runs
      parser.instance_variable_get(:@git_sources).delete(:github)

      # Call gem directly with a user/repo shorthand
      parser.send(:gem, "tool", github: "acme/tool")
      dep = parser.parsed_dependencies.last

      assert_equal "https://github.com/acme/tool.git", dep.source_options[:git]
    end
  end

  def test_github_name_only_via_inline_option_without_git_source
    with_tmpdir do |dir|
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, 'source "https://rubygems.org"')

      parser = Scint::Gemfile::Parser.new(gemfile)
      # Remove the default :github git_source so the inline option code path runs
      parser.instance_variable_get(:@git_sources).delete(:github)

      # Call gem directly with just a name (no slash) - should duplicate as name/name
      parser.send(:gem, "pry", github: "pry")
      dep = parser.parsed_dependencies.last

      assert_equal "https://github.com/pry/pry.git", dep.source_options[:git]
      refute dep.source_options.key?(:ref), "Simple repo name should not set a ref"
    end
  end
end
