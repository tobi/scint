# frozen_string_literal: true

require_relative "lockfile/parser"
require_relative "source/git"
require_relative "source/path"
require_relative "source/rubygems"
require_relative "gem/package"
require_relative "fs"
require "fileutils"
require "json"
require "open3"

module Scint
  # Materializer takes parsed lockfile specs and produces a flat directory of
  # gem sources on disk. Handles all Bundler source types: rubygems, git, path.
  #
  # Usage:
  #   lockdata = Scint::Lockfile::Parser.parse("Gemfile.lock")
  #   m = Scint::Materializer.new(cache_dir: "cache")
  #   m.materialize(lockdata)
  #   # => cache/sources/rack-3.2.4/
  #   #    cache/sources/rails-8.0.3/   (from git)
  #   #    cache/meta/rack-3.2.4.json
  #
  class Materializer
    attr_reader :source_dir, :meta_dir, :gem_cache_dir, :git_clones_dir

    def initialize(cache_dir:)
      @cache_dir      = cache_dir
      @source_dir     = File.join(cache_dir, "sources")
      @meta_dir       = File.join(cache_dir, "meta")
      @gem_cache_dir  = File.join(cache_dir, "gems")
      @git_clones_dir = File.join(cache_dir, "git-clones")
      @package        = GemPkg::Package.new
    end

    # Classify lockfile specs into { rubygems: [...], git: {...}, path: [...] }
    # Each rubygem entry: { name:, version:, source: }
    # Each git entry grouped by repo: { uri:, rev:, shortrev:, base:, gems: [{ name:, version: }] }
    # Path entries are skipped (local development gems).
    def classify(lockdata)
      rubygems = []
      git_repos = {}
      path_gems = []

      lockdata.specs.each do |spec|
        case spec[:source]
        when Source::Git
          src = spec[:source]
          rev = src.revision
          shortrev = rev[0, 12]
          base = src.name
          key = "#{base}-#{shortrev}"

          repo = (git_repos[key] ||= {
            uri: src.uri, rev: rev, base: base,
            shortrev: shortrev, branch: src.branch, tag: src.tag,
            submodules: src.submodules, glob: src.glob,
            gems: []
          })
          repo[:gems] << { name: spec[:name], version: spec[:version] } unless
            repo[:gems].any? { |g| g[:name] == spec[:name] }

        when Source::Path
          path_gems << { name: spec[:name], version: spec[:version], path: spec[:source].path }

        else
          # Rubygems source — collect all platform variants, pick best later
          source_uri = spec[:source].respond_to?(:uri) ? spec[:source].uri : "https://rubygems.org/"
          platform = spec[:platform] || "ruby"
          rubygems << { name: spec[:name], version: spec[:version], platform: platform, source_uri: source_uri }
        end
      end

      # Deduplicate rubygems: prefer "ruby" platform, else pick best match for current host
      rubygems = select_best_platform(rubygems)

      { rubygems: rubygems, git: git_repos, path: path_gems }
    end

    # Check if a rubygem is already materialized (source + metadata exist).
    def materialized?(name, version)
      File.exist?(File.join(@meta_dir, "#{name}-#{version}.json")) &&
        Dir.exist?(File.join(@source_dir, "#{name}-#{version}"))
    end

    # Materialize a single downloaded .gem file into source + metadata.
    # Returns true on success.
    def materialize_gem(gem_path, name, version)
      target = File.join(@source_dir, "#{name}-#{version}")

      unless Dir.exist?(target)
        FS.mkdir_p(@source_dir)
        result = @package.extract(gem_path, target)

        # Strip prebuilt .so/.bundle/.dylib — we compile from source
        Dir.glob(File.join(target, "**", "*.{so,bundle,dylib}")).each do |f|
          File.delete(f) rescue nil
        end
      end

      extract_metadata(gem_path, name, version)
      [true, nil]
    rescue => e
      [false, "materialize #{name}-#{version}: #{e.message}"]
    end

    # Materialize a git repo: clone, checkout rev, copy into source dirs.
    # Returns true on success.
    def materialize_git(repo)
      gems = repo[:gems]
      all_exist = gems.all? { |g| Dir.exist?(File.join(@source_dir, "#{g[:name]}-#{g[:version]}")) }
      return [true, nil] if all_exist

      clone_dir = File.join(@git_clones_dir, repo[:base])
      FS.mkdir_p(File.dirname(clone_dir))

      unless Dir.exist?(clone_dir)
        out, status = Open3.capture2e("git", "clone", "--quiet", repo[:uri], clone_dir)
        return [false, "git clone failed: #{out.strip}"] unless status.success?
      end

      out, status = Open3.capture2e("git", "-C", clone_dir, "fetch", "--quiet", "origin")
      return [false, "git fetch failed: #{out.strip}"] unless status.success?

      out, status = Open3.capture2e("git", "-C", clone_dir, "checkout", "--quiet", "--force", repo[:rev])
      return [false, "git checkout #{repo[:rev]} failed: #{out.strip}"] unless status.success?

      gems.each do |g|
        target = File.join(@source_dir, "#{g[:name]}-#{g[:version]}")
        next if Dir.exist?(target)
        # Use git checkout-index to export a clean copy without .git
        # (avoids copying unix sockets that exceed macOS 104-byte path limit)
        FileUtils.mkdir_p(target)
        out, status = Open3.capture2e("git", "-C", clone_dir, "checkout-index", "-a", "-f", "--prefix=#{target}/")
        return [false, "git checkout-index failed for #{g[:name]}: #{out.strip}"] unless status.success?
      end

      [true, nil]
    rescue => e
      [false, e.message]
    end

    # Read metadata from a materialized gem's JSON file.
    def read_metadata(name, version)
      path = File.join(@meta_dir, "#{name}-#{version}.json")
      return nil unless File.exist?(path)
      JSON.parse(File.read(path), symbolize_names: true)
    end

    # Load all metadata files.
    def all_metadata
      meta = {}
      Dir.glob(File.join(@meta_dir, "*.json")).each do |f|
        m = JSON.parse(File.read(f), symbolize_names: true)
        meta["#{m[:name]}-#{m[:version]}"] = m
      end
      meta
    end

    private

    # Given a flat list of {name:, version:, platform:, source_uri:}, group by name+version
    # and pick the best platform for each: prefer "ruby", else match the current host.
    # Adds :platform_specific => true when the gem has no "ruby" variant.
    def select_best_platform(gems)
      local = Gem::Platform.local
      grouped = gems.group_by { |g| "#{g[:name]}-#{g[:version]}" }
      grouped.map do |_key, variants|
        ruby_variant = variants.find { |v| v[:platform] == "ruby" }
        if ruby_variant
          ruby_variant[:platform_specific] = false
          next ruby_variant
        end

        # No pure-ruby variant — pick platform matching this host
        best = variants.find { |v| local =~ Gem::Platform.new(v[:platform]) } ||
               variants.first
        best[:platform_specific] = true
        best
      end.compact
    end

    def extract_metadata(gem_path, name, version)
      meta_file = File.join(@meta_dir, "#{name}-#{version}.json")
      return if File.exist?(meta_file)

      FS.mkdir_p(@meta_dir)
      gemspec = @package.read_metadata(gem_path)
      return unless gemspec

      source = File.join(@source_dir, "#{name}-#{version}")
      has_extensions = if gemspec.respond_to?(:extensions) && !gemspec.extensions.empty?
        true
      elsif Dir.exist?(source)
        !Dir.glob(File.join(source, "ext", "**", "extconf.rb")).empty?
      else
        false
      end

      result = {
        "name" => name,
        "version" => version,
        "require_paths" => gemspec.require_paths || ["lib"],
        "executables" => gemspec.executables || [],
        "bindir" => gemspec.bindir || "exe",
        "has_extensions" => has_extensions,
        "dependencies" => (gemspec.dependencies || [])
          .select { |d| d.type == :runtime }
          .map { |d| { "name" => d.name, "requirement" => d.requirement.to_s } },
      }

      FS.atomic_write(meta_file, JSON.pretty_generate(result))
    rescue => e
      $stderr.puts "  WARN: metadata #{name}-#{version}: #{e.message}"
    end
  end
end
