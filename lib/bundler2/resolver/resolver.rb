# frozen_string_literal: true

require_relative "../vendor/pub_grub"
require_relative "provider"

module Bundler2
  module Resolver
    # ResolvedSpec: the output of resolution.
    ResolvedSpec = Struct.new(
      :name, :version, :platform, :dependencies,
      :source, :has_extensions, :remote_uri, :checksum,
      keyword_init: true
    )

    # PubGrub-based dependency resolver.
    # Implements the source interface that PubGrub::VersionSolver expects.
    class Resolver
      attr_reader :provider

      # provider: Resolver::Provider instance
      # dependencies: array of Gemfile::Dependency (top-level requirements)
      # locked_specs: hash { name => version_string } for preferring locked versions
      def initialize(provider:, dependencies:, locked_specs: {})
        @provider = provider
        @dependencies = dependencies
        @locked_specs = locked_specs
        @packages = {}  # name => PubGrub::Package

        @root_package = Bundler2::PubGrub::Package.root
        @root_version = Bundler2::PubGrub::Package.root_version

        # MUST be ascending — PubGrub uses binary search in select_versions.
        @sorted_versions = Hash.new do |h, k|
          if k == @root_package
            h[k] = [@root_version]
          else
            h[k] = all_versions_for(k).sort
          end
        end

        @cached_dependencies = Hash.new do |packages, package|
          if package == @root_package
            packages[package] = { @root_version => root_dependencies }
          else
            packages[package] = Hash.new do |versions, version|
              versions[version] = dependencies_for(package, version)
            end
          end
        end
      end

      # Run resolution. Returns array of ResolvedSpec.
      def resolve
        # Prefetch all known gem info before resolution
        prefetch_all

        solver = Bundler2::PubGrub::VersionSolver.new(
          source: self,
          root: @root_package,
          logger: NullLogger.new
        )

        result = solver.solve

        result.filter_map do |package, version|
          next if Bundler2::PubGrub::Package.root?(package)
          build_resolved_spec(package, version)
        end
      end

      # --- PubGrub source interface ---

      def versions_for(package, range = Bundler2::PubGrub::VersionRange.any)
        range.select_versions(@sorted_versions[package])
      end

      def incompatibilities_for(package, version)
        package_deps = @cached_dependencies[package]
        sorted_versions = @sorted_versions[package]
        package_deps[version].map do |dep_package, dep_constraint|
          low = high = sorted_versions.index(version)

          # find version low such that all >= low share the same dep
          while low > 0 && package_deps[sorted_versions[low - 1]][dep_package] == dep_constraint
            low -= 1
          end
          low = low == 0 ? nil : sorted_versions[low]

          # find version high such that all < high share the same dep
          while high < sorted_versions.length && package_deps[sorted_versions[high]][dep_package] == dep_constraint
            high += 1
          end
          high = high == sorted_versions.length ? nil : sorted_versions[high]

          range = Bundler2::PubGrub::VersionRange.new(min: low, max: high, include_min: !low.nil?)
          self_constraint = Bundler2::PubGrub::VersionConstraint.new(package, range: range)

          dep_term = Bundler2::PubGrub::Term.new(dep_constraint, false)
          self_term = Bundler2::PubGrub::Term.new(self_constraint, true)

          Bundler2::PubGrub::Incompatibility.new([self_term, dep_term], cause: :dependency)
        end
      end

      def no_versions_incompatibility_for(_package, unsatisfied_term)
        cause = Bundler2::PubGrub::Incompatibility::NoVersions.new(unsatisfied_term)
        Bundler2::PubGrub::Incompatibility.new([unsatisfied_term], cause: cause)
      end

      # Public: PubGrub Strategy calls this to build version preference index.
      # Returns newest-first so index 0 = newest = most preferred.
      # Locked versions are promoted to the front (most preferred).
      def all_versions_for(package)
        name = package.name
        versions = @provider.versions_for(name).reverse  # newest first

        locked = @locked_specs[name]
        if locked
          locked_ver = Gem::Version.new(locked)
          # Move locked version to front if present
          if (idx = versions.index(locked_ver))
            versions.delete_at(idx)
            versions.unshift(locked_ver)
          end
        end

        versions
      end

      private

      def package_for(name)
        @packages[name] ||= Bundler2::PubGrub::Package.new(name)
      end

      def root_dependencies
        deps = {}
        @dependencies.each do |dep|
          pkg = package_for(dep.name)
          req = Gem::Requirement.new(dep.version_reqs)
          range = requirement_to_range(req)
          constraint = Bundler2::PubGrub::VersionConstraint.new(pkg, range: range)

          deps[pkg] = if deps[pkg]
            deps[pkg].intersect(constraint)
          else
            constraint
          end
        end
        deps
      end

      def dependencies_for(package, version)
        name = package.name
        dep_hash = @provider.dependencies_for(name, version)
        result = {}

        dep_hash.each do |dep_name, dep_req|
          dep_package = package_for(dep_name)
          range = requirement_to_range(dep_req)
          constraint = Bundler2::PubGrub::VersionConstraint.new(dep_package, range: range)
          result[dep_package] = constraint
        end

        result
      end

      def requirement_to_range(requirement)
        ranges = requirement.requirements.map do |(op, version)|
          case op
          when "~>"
            name = "~> #{version}"
            bump = Gem::Version.new(version.bump.to_s + ".A")
            Bundler2::PubGrub::VersionRange.new(name: name, min: version, max: bump, include_min: true)
          when ">"
            Bundler2::PubGrub::VersionRange.new(min: version)
          when ">="
            Bundler2::PubGrub::VersionRange.new(min: version, include_min: true)
          when "<"
            Bundler2::PubGrub::VersionRange.new(max: version)
          when "<="
            Bundler2::PubGrub::VersionRange.new(max: version, include_max: true)
          when "="
            Bundler2::PubGrub::VersionRange.new(min: version, max: version, include_min: true, include_max: true)
          when "!="
            Bundler2::PubGrub::VersionRange.new(min: version, max: version, include_min: true, include_max: true).invert
          else
            raise ResolveError, "bad version specifier: #{op}"
          end
        end

        ranges.inject(&:intersect)
      end

      # Prefetch compact index info for all known gem names.
      def prefetch_all
        names = Set.new
        @dependencies.each { |d| names << d.name }

        # Also include locked spec names and their transitive deps
        @locked_specs.each_key { |n| names << n }

        # Fetch versions for each unique client (populates checksums).
        # Skip path/git gems -- they don't use the compact index.
        fetched_clients = Set.new
        names.each do |name|
          next if @provider.path_or_git_gem?(name)
          client = @provider.client_for(name)
          unless fetched_clients.include?(client.source_uri)
            client.fetch_versions
            fetched_clients << client.source_uri
          end
        end

        # Prefetch all info in parallel (provider routes to correct client)
        @provider.prefetch(names.to_a)
      end

      def build_resolved_spec(package, version)
        name = package.name
        deps = @provider.dependencies_for(name, version)
        dep_list = deps.map { |n, r| { name: n, version_reqs: [r.to_s] } }

        source = @provider.source_uri_for(name)

        Bundler2::ResolvedSpec.new(
          name: name,
          version: version.to_s,
          platform: "ruby",
          dependencies: dep_list,
          source: source,
          has_extensions: @provider.has_extensions?(name, version),
          remote_uri: nil,
          checksum: nil,
        )
      end

      # Minimal logger that discards output (PubGrub requires a logger).
      class NullLogger
        def info(&block) = nil
        def debug(&block) = nil
        def warn(&block) = nil
        def error(&block) = nil
        def level=(v); end
      end
    end
  end
end
