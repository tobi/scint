# frozen_string_literal: true

require "yaml"
require "uri"
require "cgi"

module Scint
  # Session-scoped credential store for HTTP gem sources.
  #
  # Assembled early from config files, then enriched as Gemfiles and lockfiles
  # are parsed. By download time, all credentials are available.
  #
  # Lookup order (first match wins):
  #   1. Inline credentials in the request URI itself (user:pass@host)
  #   2. Credentials registered at runtime (from Gemfile source: URIs)
  #   3. Bundler local config: $BUNDLE_APP_CONFIG/config or ./.bundle/config
  #   4. Scint config:   $XDG_CONFIG_HOME/scint/credentials
  #   5. Bundler global config: ~/.bundle/config
  #   6. Environment variables (BUNDLE_HOST__NAME / BUNDLE_HTTPS://... format)
  #
  # All config files use Bundler's key format:
  #   BUNDLE_PKGS__SHOPIFY__IO: "token:secret"
  #
  # Key derivation: dots → __, dashes → ___, uppercased, BUNDLE_ prefix.
  # Value is "user:password" for HTTP Basic Auth.
  class Credentials
    def initialize
      @registered = {} # "host" => "user:password"
      @mutex = Thread::Mutex.new
      @file_config = load_config_files
    end

    # Register credentials extracted from a URI with inline user:pass@host.
    # Call from Gemfile/lockfile parsing so creds survive lockfile round-trips.
    def register_uri(uri)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      return unless uri.user

      user = CGI.unescape(uri.user)
      password = uri.password ? CGI.unescape(uri.password) : nil
      auth = password ? "#{user}:#{password}" : user

      @mutex.synchronize { @registered[uri.host] = auth }
    end

    # Scan an array of source hashes (from Gemfile parser) for inline creds.
    def register_sources(sources)
      sources.each do |src|
        register_uri(src[:uri]) if src[:uri]
      end
    end

    # Scan dependencies for source: options with inline creds.
    def register_dependencies(dependencies)
      dependencies.each do |dep|
        src = dep.respond_to?(:source_options) ? dep.source_options[:source] : nil
        register_uri(src) if src
      end
    end

    # Scan lockfile source objects for remotes with inline creds.
    def register_lockfile_sources(sources)
      sources.each do |src|
        if src.respond_to?(:remotes)
          src.remotes.each { |r| register_uri(r) }
        elsif src.respond_to?(:uri)
          register_uri(src.uri)
        end
      end
    end

    # Returns [user, password] for the given URI, or nil.
    def for_uri(uri)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)

      # 1. Inline credentials in the URI itself
      if uri.user
        user = CGI.unescape(uri.user)
        password = uri.password ? CGI.unescape(uri.password) : nil
        return [user, password]
      end

      # 2–5. Registered + config files + env
      auth = lookup_uri(uri)
      return nil unless auth

      user, password = auth.split(":", 2)
      [user, password]
    end

    # Apply Basic Auth to a Net::HTTP::Request if credentials exist.
    def apply!(request, uri)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      creds = for_uri(uri)
      return unless creds

      user, password = creds
      request.basic_auth(user, password || "")
    end

    private

    def lookup_uri(uri)
      return nil unless uri&.host

      # 2. Runtime-registered (from Gemfile inline URIs)
      registered = @mutex.synchronize { @registered[uri.host] }
      return registered if registered

      # 3–5. Config files (bundler local, scint, bundler global)
      keys = self.class.keys_for_uri_lookup(uri)
      keys.each do |key|
        val = @file_config[key]
        return val if val
      end

      # 6. Environment variable
      keys.each do |key|
        val = ENV[key]
        return val if val
      end

      nil
    end

    def load_config_files
      config = {}
      # Load in reverse priority (later overrides earlier)
      load_yaml_into(config, bundler_global_config_path)
      load_yaml_into(config, scint_credentials_path)
      load_yaml_into(config, bundler_local_config_path)
      config
    end

    def load_yaml_into(config, path)
      return unless path && File.exist?(path)

      data = YAML.safe_load(File.read(path))
      config.merge!(data) if data.is_a?(Hash)
    rescue StandardError
      # Ignore malformed files
    end

    def scint_credentials_path
      xdg = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
      File.join(xdg, "scint", "credentials")
    end

    def bundler_local_config_path
      app_config = ENV["BUNDLE_APP_CONFIG"]
      dir = if app_config && !app_config.empty?
        app_config
      else
        File.join(Dir.pwd, ".bundle")
      end
      File.join(dir, "config")
    end

    def bundler_global_config_path
      File.join(Dir.home, ".bundle", "config")
    end

    # Convert "pkgs.shopify.io" → "BUNDLE_PKGS__SHOPIFY__IO"
    def self.key_for_host(host)
      key = host.to_s.dup
      key.gsub!(".", "__")
      key.gsub!("-", "___")
      key.upcase!
      "BUNDLE_#{key}"
    end

    def self.key_for_uri_string(uri_string)
      key = uri_string.to_s.dup
      key.gsub!(".", "__")
      key.gsub!("-", "___")
      key.upcase!
      "BUNDLE_#{key}"
    end

    def self.key_for_source_uri(uri)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      keys_for_uri_lookup(uri).find { |key| key != key_for_host(uri.host) }
    rescue StandardError
      nil
    end

    def self.keys_for_uri_lookup(uri)
      uri = URI.parse(uri.to_s) unless uri.is_a?(URI)
      keys = []

      normalized = "#{uri.scheme || 'https'}://#{uri.host}"
      default_port = (uri.scheme == "http" ? 80 : 443)
      normalized += ":#{uri.port}" if uri.port && uri.port != default_port

      path = uri.path.to_s
      path = "/" if path.empty?
      path = "/#{path}" unless path.start_with?("/")
      path += "/" unless path.end_with?("/")

      segments = path.split("/").reject(&:empty?)
      candidate_paths = ["/"]
      unless segments.empty?
        1.upto(segments.length) do |i|
          candidate_paths << "/#{segments.first(i).join('/')}/"
        end
      end

      candidate_paths.reverse_each do |candidate_path|
        keys << key_for_uri_string("#{normalized}#{candidate_path}")
      end

      keys << key_for_host(uri.host) if uri.host
      keys.compact.uniq
    end
  end
end
