# frozen_string_literal: true

require_relative "../test_helper"
require "scint/gemfile/editor"

class GemfileEditorTest < Minitest::Test
  def test_add_appends_new_gem
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        editor = Scint::Gemfile::Editor.new("Gemfile")
        result = editor.add("rack")

        assert_equal :added, result
        assert_includes File.read("Gemfile"), "gem \"rack\""
      end
    end
  end

  def test_add_updates_existing_gem_line
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"
          gem "rack", "~> 2.0"
        RUBY

        editor = Scint::Gemfile::Editor.new("Gemfile")
        result = editor.add("rack", requirement: "~> 3.0", group: "development")

        assert_equal :updated, result
        contents = File.read("Gemfile")
        assert_includes contents, "gem \"rack\", \"~> 3.0\", group: :development"
        refute_includes contents, "~> 2.0"
      end
    end
  end

  def test_remove_deletes_matching_single_line_entry
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"
          gem "rack"
          gem "rake"
        RUBY

        editor = Scint::Gemfile::Editor.new("Gemfile")
        removed = editor.remove("rack")

        assert_equal true, removed
        contents = File.read("Gemfile")
        refute_includes contents, "gem \"rack\""
        assert_includes contents, "gem \"rake\""
      end
    end
  end

  def test_remove_returns_false_when_gem_missing
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        editor = Scint::Gemfile::Editor.new("Gemfile")
        assert_equal false, editor.remove("rack")
      end
    end
  end
end
