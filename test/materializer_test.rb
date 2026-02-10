# frozen_string_literal: true

require "test_helper"
require "scint/materializer"

class MaterializerTest < Minitest::Test
  LOCKFILE_RUBYGEMS_ONLY = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rack (3.2.4)
        json (2.10.1)
        nokogiri (1.19.0)
          mini_portile2 (~> 2.8.2)
        mini_portile2 (2.8.9)

    PLATFORMS
      ruby

    DEPENDENCIES
      rack
      json
      nokogiri

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_GIT_BRANCH = <<~LOCK
    GIT
      remote: https://github.com/rails/rails.git
      revision: 60d92e4e7dfe923528ccdccc18820ccfe841b7b8
      branch: main
      specs:
        activesupport (8.2.0.alpha)
          concurrent-ruby (~> 1.0)
        actionpack (8.2.0.alpha)
          activesupport (= 8.2.0.alpha)

    GEM
      remote: https://rubygems.org/
      specs:
        concurrent-ruby (1.3.6)

    PLATFORMS
      ruby

    DEPENDENCIES
      rails!
      concurrent-ruby

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_GIT_TAG = <<~LOCK
    GIT
      remote: https://github.com/redis/redis-rb.git
      revision: abc123def456abc123def456abc123def456abc1
      tag: v5.0.0
      specs:
        redis (5.0.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.3.1)

    PLATFORMS
      ruby

    DEPENDENCIES
      redis!
      rake

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_GIT_REF = <<~LOCK
    GIT
      remote: https://github.com/nickel-city/webpush.git
      revision: 9631ac63045cfabddacc69fc06e919b4c13eb913
      ref: 9631ac63045cfabddacc69fc06e919b4c13eb913
      specs:
        webpush (3.0.1)
          jwt (~> 2.0)

    GEM
      remote: https://rubygems.org/
      specs:
        jwt (2.10.1)

    PLATFORMS
      ruby

    DEPENDENCIES
      webpush!
      jwt

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_GIT_GLOB = <<~LOCK
    GIT
      remote: https://github.com/example/monorepo.git
      revision: 1234567890ab1234567890ab1234567890ab1234
      branch: main
      glob: gems/*/*.gemspec
      specs:
        foo (1.0.0)
        bar (2.0.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.3.1)

    PLATFORMS
      ruby

    DEPENDENCIES
      foo!
      bar!
      rake

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_PATH_RELATIVE = <<~LOCK
    PATH
      remote: ../my-local-gem
      specs:
        my-local-gem (0.1.0)

    PATH
      remote: .
      specs:
        myapp (1.0.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.3.1)

    PLATFORMS
      ruby

    DEPENDENCIES
      myapp!
      my-local-gem!
      rake

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_MIXED = <<~LOCK
    GIT
      remote: https://github.com/example/cool-gem.git
      revision: aabbccdd11223344aabbccdd11223344aabbccdd
      branch: main
      specs:
        cool-gem (0.5.0)

    PATH
      remote: .
      specs:
        myapp (1.0.0)

    PATH
      remote: ../shared-lib
      specs:
        shared-lib (2.0.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rack (3.2.4)

    PLATFORMS
      ruby

    DEPENDENCIES
      cool-gem!
      myapp!
      shared-lib!
      rack

    BUNDLED WITH
       2.6.9
  LOCK

  LOCKFILE_PLATFORM_DUPES = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        nokogiri (1.19.0)
          mini_portile2 (~> 2.8.2)
        nokogiri (1.19.0-x86_64-linux)
          mini_portile2 (~> 2.8.2)
        mini_portile2 (2.8.9)

    PLATFORMS
      ruby
      x86_64-linux

    DEPENDENCIES
      nokogiri

    BUNDLED WITH
       2.6.9
  LOCK

  def setup
    @tmpdir = Dir.mktmpdir("materializer-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def mat
    @mat ||= Scint::Materializer.new(cache_dir: @tmpdir)
  end

  def parse(text)
    Scint::Lockfile::Parser.parse(text)
  end

  # --- classify: rubygems ---

  def test_classify_rubygems_only
    c = mat.classify(parse(LOCKFILE_RUBYGEMS_ONLY))
    names = c[:rubygems].map { |g| g[:name] }.sort
    assert_equal %w[json mini_portile2 nokogiri rack], names
    assert_empty c[:git]
    assert_empty c[:path]
  end

  def test_classify_rubygems_includes_version
    c = mat.classify(parse(LOCKFILE_RUBYGEMS_ONLY))
    rack = c[:rubygems].find { |g| g[:name] == "rack" }
    assert_equal "3.2.4", rack[:version]
  end

  # --- classify: git sources ---

  def test_classify_git_branch
    c = mat.classify(parse(LOCKFILE_GIT_BRANCH))
    assert_equal 1, c[:git].size
    key, repo = c[:git].first
    assert_equal "rails", repo[:base]
    assert_equal "main", repo[:branch]
    assert_nil repo[:tag]
    assert_equal "60d92e4e7dfe", repo[:shortrev]
    assert_equal 2, repo[:gems].size
    gem_names = repo[:gems].map { |g| g[:name] }.sort
    assert_equal %w[actionpack activesupport], gem_names
  end

  def test_classify_git_tag
    c = mat.classify(parse(LOCKFILE_GIT_TAG))
    _key, repo = c[:git].first
    assert_equal "v5.0.0", repo[:tag]
    assert_nil repo[:branch]
    assert_equal "redis", repo[:gems].first[:name]
  end

  def test_classify_git_ref
    c = mat.classify(parse(LOCKFILE_GIT_REF))
    _key, repo = c[:git].first
    assert_equal "9631ac63045cfabddacc69fc06e919b4c13eb913", repo[:rev]
    assert_equal "9631ac63045c", repo[:shortrev]
    assert_equal "webpush", repo[:gems].first[:name]
  end

  def test_classify_git_glob
    c = mat.classify(parse(LOCKFILE_GIT_GLOB))
    _key, repo = c[:git].first
    assert_equal "gems/*/*.gemspec", repo[:glob]
    gem_names = repo[:gems].map { |g| g[:name] }.sort
    assert_equal %w[bar foo], gem_names
  end

  def test_classify_git_monorepo_groups_gems_under_one_repo
    c = mat.classify(parse(LOCKFILE_GIT_BRANCH))
    # Both activesupport and actionpack come from the same rails repo
    assert_equal 1, c[:git].size
    _key, repo = c[:git].first
    assert_equal 2, repo[:gems].size
  end

  # --- classify: path sources ---

  def test_classify_path_relative_dot
    c = mat.classify(parse(LOCKFILE_PATH_RELATIVE))
    dot = c[:path].find { |g| g[:path] == "." }
    assert_equal "myapp", dot[:name]
  end

  def test_classify_path_relative_parent
    c = mat.classify(parse(LOCKFILE_PATH_RELATIVE))
    parent = c[:path].find { |g| g[:path] == "../my-local-gem" }
    assert_equal "my-local-gem", parent[:name]
    assert_equal "0.1.0", parent[:version]
  end

  # --- classify: mixed ---

  def test_classify_mixed_all_types
    c = mat.classify(parse(LOCKFILE_MIXED))
    assert_equal 1, c[:rubygems].size
    assert_equal "rack", c[:rubygems].first[:name]

    assert_equal 1, c[:git].size
    _key, repo = c[:git].first
    assert_equal "cool-gem", repo[:gems].first[:name]

    assert_equal 2, c[:path].size
    paths = c[:path].map { |g| g[:path] }.sort
    assert_equal %w[. ../shared-lib], paths
  end

  # --- classify: platform dedup ---

  def test_classify_deduplicates_platform_gems
    c = mat.classify(parse(LOCKFILE_PLATFORM_DUPES))
    noko = c[:rubygems].select { |g| g[:name] == "nokogiri" }
    assert_equal 1, noko.size, "should deduplicate platform-specific gems"
  end

  # --- materialized? ---

  def test_materialized_false_when_empty
    refute mat.materialized?("rack", "3.2.4")
  end

  def test_materialized_true_when_present
    FileUtils.mkdir_p(File.join(@tmpdir, "sources", "rack-3.2.4"))
    FileUtils.mkdir_p(File.join(@tmpdir, "meta"))
    File.write(File.join(@tmpdir, "meta", "rack-3.2.4.json"), '{"name":"rack"}')
    assert mat.materialized?("rack", "3.2.4")
  end

  # --- materialize_gem ---

  def test_materialize_gem_extracts_and_creates_metadata
    gem_path = File.join(@tmpdir, "test.gem")
    create_fake_gem(gem_path, name: "test-gem", version: "1.0.0",
                    files: { "lib/test_gem.rb" => "# hello" })

    result = mat.materialize_gem(gem_path, "test-gem", "1.0.0")
    assert result

    assert Dir.exist?(File.join(@tmpdir, "sources", "test-gem-1.0.0"))
    assert File.exist?(File.join(@tmpdir, "sources", "test-gem-1.0.0", "lib", "test_gem.rb"))
    assert File.exist?(File.join(@tmpdir, "meta", "test-gem-1.0.0.json"))

    meta = JSON.parse(File.read(File.join(@tmpdir, "meta", "test-gem-1.0.0.json")))
    assert_equal "test-gem", meta["name"]
    assert_equal "1.0.0", meta["version"]
    assert_equal ["lib"], meta["require_paths"]
  end

  def test_materialize_gem_strips_prebuilt_so_files
    gem_path = File.join(@tmpdir, "ffi.gem")
    create_fake_gem(gem_path, name: "ffi", version: "1.0.0",
                    files: {
                      "lib/ffi.rb" => "# ruby",
                      "lib/ffi_c.so" => "ELF binary",
                      "ext/ffi_c/ffi.bundle" => "Mach-O binary",
                    })

    mat.materialize_gem(gem_path, "ffi", "1.0.0")

    source_dir = File.join(@tmpdir, "sources", "ffi-1.0.0")
    assert File.exist?(File.join(source_dir, "lib", "ffi.rb"))
    refute File.exist?(File.join(source_dir, "lib", "ffi_c.so")), "should strip .so"
    refute File.exist?(File.join(source_dir, "ext", "ffi_c", "ffi.bundle")), "should strip .bundle"
  end

  def test_materialize_gem_idempotent
    gem_path = File.join(@tmpdir, "test.gem")
    create_fake_gem(gem_path, name: "rack", version: "3.2.4",
                    files: { "lib/rack.rb" => "# rack" })

    assert mat.materialize_gem(gem_path, "rack", "3.2.4")
    assert mat.materialize_gem(gem_path, "rack", "3.2.4") # second call is a no-op
    assert mat.materialized?("rack", "3.2.4")
  end

  # --- read_metadata ---

  def test_read_metadata_returns_nil_when_missing
    assert_nil mat.read_metadata("nonexistent", "1.0.0")
  end

  def test_read_metadata_returns_parsed_json
    FileUtils.mkdir_p(File.join(@tmpdir, "meta"))
    data = { name: "rack", version: "3.2.4", require_paths: ["lib"] }
    File.write(File.join(@tmpdir, "meta", "rack-3.2.4.json"), JSON.generate(data))

    meta = mat.read_metadata("rack", "3.2.4")
    assert_equal "rack", meta[:name]
    assert_equal ["lib"], meta[:require_paths]
  end

  # --- all_metadata ---

  def test_all_metadata_loads_all_json_files
    FileUtils.mkdir_p(File.join(@tmpdir, "meta"))
    %w[rack-3.2.4 json-2.10.1].each do |key|
      name, version = key.split("-", 2)
      File.write(File.join(@tmpdir, "meta", "#{key}.json"),
                 JSON.generate(name: name, version: version))
    end

    all = mat.all_metadata
    assert_equal 2, all.size
    assert all.key?("rack-3.2.4")
    assert all.key?("json-2.10.1")
  end

  # --- directory structure ---

  def test_directory_structure
    assert_equal File.join(@tmpdir, "sources"), mat.source_dir
    assert_equal File.join(@tmpdir, "meta"), mat.meta_dir
    assert_equal File.join(@tmpdir, "gems"), mat.gem_cache_dir
    assert_equal File.join(@tmpdir, "git-clones"), mat.git_clones_dir
  end
end
