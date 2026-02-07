# frozen_string_literal: true

require_relative "test_helper"
require "scint/credentials"
require "net/http"

class CredentialsTest < Minitest::Test
  def setup
    @creds = Scint::Credentials.new
  end

  # --- key_for_host ---

  def test_key_for_host_converts_dots_to_double_underscores
    assert_equal "BUNDLE_RUBYGEMS__ORG", Scint::Credentials.key_for_host("rubygems.org")
  end

  def test_key_for_host_converts_dashes_to_triple_underscores
    assert_equal "BUNDLE_MY___GEM__IO", Scint::Credentials.key_for_host("my-gem.io")
  end

  def test_key_for_host_uppercases
    assert_equal "BUNDLE_PKGS__SHOPIFY__IO", Scint::Credentials.key_for_host("pkgs.shopify.io")
  end

  # --- register_uri ---

  def test_register_uri_with_user_and_password
    @creds.register_uri("https://user:pass@gems.example.com/")
    result = @creds.for_uri("https://gems.example.com/specs.4.8.gz")
    assert_equal ["user", "pass"], result
  end

  def test_register_uri_with_user_only
    @creds.register_uri("https://tokenuser@gems.example.com/")
    result = @creds.for_uri("https://gems.example.com/specs.4.8.gz")
    assert_equal ["tokenuser", nil], result
  end

  def test_register_uri_skips_when_no_user
    @creds.register_uri("https://gems.example.com/")
    result = @creds.for_uri("https://gems.example.com/specs.4.8.gz")
    assert_nil result
  end

  def test_register_uri_accepts_uri_object
    @creds.register_uri(URI.parse("https://user:secret@gems.example.com/"))
    result = @creds.for_uri("https://gems.example.com/specs.4.8.gz")
    assert_equal ["user", "secret"], result
  end

  def test_register_uri_unescapes_percent_encoded_creds
    @creds.register_uri("https://u%40ser:p%3Ass@gems.example.com/")
    result = @creds.for_uri("https://gems.example.com/foo")
    assert_equal ["u@ser", "p:ss"], result
  end

  # --- register_sources ---

  def test_register_sources_extracts_inline_creds
    sources = [
      { type: :rubygems, uri: "https://token:secret@private.example.com/" },
      { type: :rubygems, uri: "https://rubygems.org/" },
    ]
    @creds.register_sources(sources)
    result = @creds.for_uri("https://private.example.com/specs.4.8.gz")
    assert_equal ["token", "secret"], result
  end

  def test_register_sources_skips_sources_without_uri
    sources = [{ type: :path, path: "/local/gems" }]
    @creds.register_sources(sources)
    # should not raise
  end

  # --- register_dependencies ---

  def test_register_dependencies_extracts_source_option_creds
    dep = Object.new
    dep.define_singleton_method(:source_options) { { source: "https://u:p@dep-host.com/" } }
    @creds.register_dependencies([dep])

    result = @creds.for_uri("https://dep-host.com/gems/foo")
    assert_equal ["u", "p"], result
  end

  def test_register_dependencies_handles_dep_without_source_options
    dep = Object.new
    @creds.register_dependencies([dep])
    # should not raise
  end

  # --- register_lockfile_sources ---

  def test_register_lockfile_sources_with_remotes
    src = Object.new
    src.define_singleton_method(:remotes) { ["https://a:b@lock-host.com/"] }
    @creds.register_lockfile_sources([src])

    result = @creds.for_uri("https://lock-host.com/foo")
    assert_equal ["a", "b"], result
  end

  def test_register_lockfile_sources_with_uri
    src = Object.new
    src.define_singleton_method(:uri) { "https://x:y@uri-host.com/" }
    @creds.register_lockfile_sources([src])

    result = @creds.for_uri("https://uri-host.com/foo")
    assert_equal ["x", "y"], result
  end

  # --- for_uri ---

  def test_for_uri_returns_inline_creds_from_uri
    result = @creds.for_uri("https://inline:cred@example.com/path")
    assert_equal ["inline", "cred"], result
  end

  def test_for_uri_returns_inline_user_only
    result = @creds.for_uri("https://justuser@example.com/path")
    assert_equal ["justuser", nil], result
  end

  def test_for_uri_returns_nil_when_no_creds
    result = @creds.for_uri("https://no-creds-host-abc123.example.com/path")
    assert_nil result
  end

  def test_for_uri_accepts_uri_object
    result = @creds.for_uri(URI.parse("https://u2:p2@example.com/path"))
    assert_equal ["u2", "p2"], result
  end

  def test_for_uri_splits_registered_auth_on_colon
    @creds.register_uri("https://myuser:mypass@cred-host.com/")
    user, pass = @creds.for_uri("https://cred-host.com/gems")
    assert_equal "myuser", user
    assert_equal "mypass", pass
  end

  # --- for_uri via env var ---

  def test_for_uri_falls_back_to_env_var
    key = "BUNDLE_ENV___CRED___HOST__COM"
    with_env(key, "envuser:envpass") do
      result = @creds.for_uri("https://env-cred-host.com/gems")
      assert_equal ["envuser", "envpass"], result
    end
  end

  # --- for_uri via config files ---

  def test_for_uri_loads_from_scint_config_file
    with_tmpdir do |dir|
      config_dir = File.join(dir, "scint")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "credentials"),
                 "BUNDLE_FILE___HOST__COM: \"fileuser:filepass\"\n")

      with_env("XDG_CONFIG_HOME", dir) do
        creds = Scint::Credentials.new
        result = creds.for_uri("https://file-host.com/gems")
        assert_equal ["fileuser", "filepass"], result
      end
    end
  end

  def test_for_uri_loads_from_bundler_config_file
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      FileUtils.mkdir_p(bundle_dir)
      File.write(File.join(bundle_dir, "config"),
                 "BUNDLE_BNDL___HOST__COM: \"buser:bpass\"\n")

      # Stub Dir.home to return our tmpdir
      Dir.stub(:home, dir) do
        creds = Scint::Credentials.new
        result = creds.for_uri("https://bndl-host.com/gems")
        assert_equal ["buser", "bpass"], result
      end
    end
  end

  def test_scint_config_overrides_bundler_config
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      FileUtils.mkdir_p(bundle_dir)
      File.write(File.join(bundle_dir, "config"),
                 "BUNDLE_OVERRIDE___HOST__COM: \"bundler_user:bundler_pass\"\n")

      config_dir = File.join(dir, "scint")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "credentials"),
                 "BUNDLE_OVERRIDE___HOST__COM: \"scint_user:scint_pass\"\n")

      with_env("XDG_CONFIG_HOME", dir) do
        Dir.stub(:home, dir) do
          creds = Scint::Credentials.new
          result = creds.for_uri("https://override-host.com/gems")
          assert_equal ["scint_user", "scint_pass"], result
        end
      end
    end
  end

  def test_load_config_ignores_malformed_yaml
    with_tmpdir do |dir|
      config_dir = File.join(dir, "scint")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "credentials"), "{{{{not yaml at all")

      with_env("XDG_CONFIG_HOME", dir) do
        creds = Scint::Credentials.new
        # Should not raise, returns nil for unknown hosts
        assert_nil creds.for_uri("https://no-such-host.com/gems")
      end
    end
  end

  # --- apply! ---

  def test_apply_sets_basic_auth_on_request
    @creds.register_uri("https://applyuser:applypass@apply-host.com/")
    request = Net::HTTP::Get.new("/gems")
    @creds.apply!(request, "https://apply-host.com/gems")

    # basic_auth sets the Authorization header
    assert request["Authorization"]
    assert_match(/Basic/, request["Authorization"])
  end

  def test_apply_does_nothing_when_no_creds
    request = Net::HTTP::Get.new("/gems")
    @creds.apply!(request, "https://no-creds-host-xyz.com/gems")
    assert_nil request["Authorization"]
  end

  def test_apply_uses_empty_string_for_nil_password
    @creds.register_uri("https://tokenonly@token-host.com/")
    request = Net::HTTP::Get.new("/gems")
    @creds.apply!(request, "https://token-host.com/gems")
    assert request["Authorization"]
  end

  # --- lookup_host nil host ---

  def test_for_uri_returns_nil_for_nil_host
    # A URI without a host, e.g. "file:///local/path"
    result = @creds.for_uri("file:///local/path")
    assert_nil result
  end
end
