# frozen_string_literal: true

require "pathname"
require "base64"
require "bundler2/runtime/setup"
require "bundler2/gemfile/parser"

# Minimal Bundler compatibility shim for `bundle2 exec`.
# This intentionally implements only the subset commonly used by apps:
# - `require "bundler/setup"` (handled by lib/bundler/setup.rb)
# - `Bundler.setup`
# - `Bundler.require`
module Bundler
  RUNTIME_LOCK = "bundler2.lock.marshal"
  ORIGINAL_ENV = begin
    encoded = ENV["BUNDLER2_ORIGINAL_ENV"]
    if encoded && !encoded.empty?
      Marshal.load(Base64.decode64(encoded))
    else
      ENV.to_hash
    end
  rescue StandardError
    ENV.to_hash
  end

  class << self
    def setup(*_groups)
      return @lock_data if @lock_data

      lock_path = find_runtime_lock
      unless lock_path
        raise LoadError, "Runtime lock not found. Run `bundle2 install` first."
      end

      ENV["BUNDLER2_RUNTIME_LOCK"] ||= lock_path
      @lock_data = ::Bundler2::Runtime::Setup.setup(lock_path)
    end

    def require(*_groups)
      groups = _groups.flatten.compact.map(&:to_sym)
      groups = [:default] if groups.empty?

      setup

      gemfile_dependencies.each do |dep|
        next unless dependency_in_groups?(dep, groups)

        targets = require_targets_for(dep)
        targets.each { |target| require_one(target) }
      end

      true
    end

    def root
      gemfile = ENV["BUNDLE_GEMFILE"]
      return Pathname.new(Dir.pwd) unless gemfile && !gemfile.empty?

      Pathname.new(File.dirname(gemfile))
    end

    def bundle_path
      root.join(".bundle")
    end

    def load
      setup
    end

    def with_unbundled_env
      previous = ENV.to_hash
      ENV.replace(unbundled_env)
      yield
    ensure
      ENV.replace(previous) if previous
    end
    alias with_original_env with_unbundled_env

    def original_env
      ORIGINAL_ENV.dup
    end

    def unbundled_env
      env = original_env
      env["RUBYOPT"] = filter_bundler_setup_from_rubyopt(env["RUBYOPT"])
      env.delete("BUNDLER2_RUNTIME_LOCK")
      env.delete("BUNDLER2_ORIGINAL_ENV")
      env
    end

    private

    def require_one(gem_name)
      name = gem_name.to_s
      candidates = [name, name.tr("-", "_"), name.tr("-", "/")].uniq
      last_error = nil

      candidates.each do |candidate|
        begin
          Kernel.require(candidate)
          return true
        rescue LoadError => e
          last_error = e
        end
      end

      raise last_error if last_error
    end

    def gemfile_dependencies
      return @gemfile_dependencies if defined?(@gemfile_dependencies)

      gemfile = ENV["BUNDLE_GEMFILE"]
      @gemfile_dependencies =
        if gemfile && File.exist?(gemfile)
          ::Bundler2::Gemfile::Parser.parse(gemfile).dependencies
        else
          []
        end
    rescue StandardError
      @gemfile_dependencies = []
    end

    def dependency_in_groups?(dep, groups)
      dep_groups = Array(dep.groups).map(&:to_sym)
      (dep_groups & groups).any?
    end

    def require_targets_for(dep)
      req = dep.require_paths
      return [] if req == []
      return [dep.name] if req.nil?

      Array(req)
    end

    def find_runtime_lock
      env_path = ENV["BUNDLER2_RUNTIME_LOCK"]
      return env_path if env_path && File.exist?(env_path)

      gemfile = ENV["BUNDLE_GEMFILE"]
      if gemfile && !gemfile.empty?
        candidate = File.join(File.dirname(gemfile), ".bundle", RUNTIME_LOCK)
        return candidate if File.exist?(candidate)
      end

      dir = Dir.pwd
      loop do
        candidate = File.join(dir, ".bundle", RUNTIME_LOCK)
        return candidate if File.exist?(candidate)

        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end

      nil
    end

    def filter_bundler_setup_from_rubyopt(value)
      parts = value.to_s.split(/\s+/).reject(&:empty?)
      filtered = parts.reject do |entry|
        entry == "-rbundler/setup" || entry.end_with?("/bundler/setup")
      end
      filtered.join(" ")
    end
  end
end
