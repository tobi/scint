# frozen_string_literal: true

require "pathname"
require "base64"
require "scint/runtime/setup"
require "scint/gemfile/parser"

# Minimal Bundler compatibility shim for `scint exec`.
# This intentionally implements only the subset commonly used by apps:
# - `require "bundler/setup"` (handled by lib/bundler/setup.rb)
# - `Bundler.setup`
# - `Bundler.require`
module Bundler
  RUNTIME_LOCK = "scint.lock.marshal"
  ORIGINAL_ENV = begin
    encoded = ENV["SCINT_ORIGINAL_ENV"]
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
        raise LoadError, "Runtime lock not found. Run `scint install` first."
      end

      ENV["SCINT_RUNTIME_LOCK"] ||= lock_path
      @lock_data = ::Scint::Runtime::Setup.setup(lock_path)
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
      env.delete("SCINT_RUNTIME_LOCK")
      env.delete("SCINT_ORIGINAL_ENV")
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

      return true if require_matching_basename(name)

      raise last_error if last_error
    end

    def gemfile_dependencies
      return @gemfile_dependencies if defined?(@gemfile_dependencies)

      gemfile = ENV["BUNDLE_GEMFILE"]
      @gemfile_dependencies =
        if gemfile && File.exist?(gemfile)
          ::Scint::Gemfile::Parser.parse(gemfile).dependencies
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
      env_path = ENV["SCINT_RUNTIME_LOCK"]
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

    def require_matching_basename(name)
      target = normalize_basename(name)
      return false if target.empty?

      exact_candidates = []
      fuzzy_candidates = []

      $LOAD_PATH.each do |load_dir|
        next unless File.directory?(load_dir)

        Dir.children(load_dir).sort.each do |entry|
          next unless entry.end_with?(".rb")

          basename = entry.delete_suffix(".rb")
          normalized = normalize_basename(basename)
          if normalized == target
            exact_candidates << basename
          elsif compatible_basename?(target, normalized)
            fuzzy_candidates << [basename, normalized]
          end
        end
      rescue StandardError
        next
      end

      exact_candidates.uniq.each do |candidate|
        begin
          Kernel.require(candidate)
          return true
        rescue LoadError
          next
        end
      end

      fuzzy_candidates
        .uniq
        .sort_by { |_basename, normalized| [((target.length - normalized.length).abs), -normalized.length] }
        .map(&:first)
        .each do |candidate|
          begin
            Kernel.require(candidate)
            return true
          rescue LoadError
            next
          end
        end

      false
    end

    def normalize_basename(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    def compatible_basename?(target, normalized)
      return false if target.length < 4 || normalized.length < 4

      target_variants = basename_variants(target)
      normalized_variants = basename_variants(normalized)
      return true if (target_variants & normalized_variants).any?

      target_variants.any? do |t|
        normalized_variants.any? { |n| t.start_with?(n) || n.start_with?(t) }
      end
    end

    def basename_variants(name)
      value = name.to_s.downcase
      variants = [value]

      plural_to_s = value.sub(/ties\z/, "s")
      plural_to_y = value.sub(/ies\z/, "y")
      singular = value.sub(/s\z/, "")

      variants << plural_to_s unless plural_to_s == value
      variants << plural_to_y unless plural_to_y == value
      variants << singular unless singular == value
      variants.uniq.select { |v| v.length >= 4 }
    end
  end
end
