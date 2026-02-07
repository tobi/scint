# frozen_string_literal: true

module Bundler2
  VERSION = "0.1.0"

  # XDG-based cache root
  def self.cache_root
    @cache_root ||= File.join(
      ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")),
      "bundler2"
    )
  end

  def self.cache_root=(path)
    @cache_root = path
  end

  # Shared data structures used across all modules
  Dependency = Struct.new(
    :name, :version_reqs, :source, :groups, :platforms, :require_paths,
    keyword_init: true
  )

  LockedSpec = Struct.new(
    :name, :version, :platform, :dependencies, :source, :checksum,
    keyword_init: true
  )

  ResolvedSpec = Struct.new(
    :name, :version, :platform, :dependencies, :source, :has_extensions,
    :remote_uri, :checksum,
    keyword_init: true
  )

  PlanEntry = Struct.new(
    :spec, :action, :cached_path, :gem_path,
    keyword_init: true
  )

  PreparedGem = Struct.new(
    :spec, :extracted_path, :gemspec, :from_cache,
    keyword_init: true
  )

  # Autoloads — each file is loaded on first reference
  autoload :CLI,         "bundler2/cli"
  autoload :Scheduler,   "bundler2/scheduler"
  autoload :WorkerPool,  "bundler2/worker_pool"
  autoload :Progress,    "bundler2/progress"
  autoload :FS,          "bundler2/fs"
  autoload :Platform,    "bundler2/platform"

  # Errors
  autoload :BundlerError,        "bundler2/errors"
  autoload :GemfileError,        "bundler2/errors"
  autoload :LockfileError,       "bundler2/errors"
  autoload :ResolveError,        "bundler2/errors"
  autoload :NetworkError,        "bundler2/errors"
  autoload :InstallError,        "bundler2/errors"
  autoload :ExtensionBuildError, "bundler2/errors"
  autoload :PermissionError,     "bundler2/errors"
  autoload :PlatformError,       "bundler2/errors"
  autoload :CacheError,          "bundler2/errors"

  # Submodule namespaces — defined here so autoloads don't trigger
  # when files inside these modules reference the module name.
  module Gemfile; end
  module Lockfile; end
  module Resolver; end
  module Index; end
  module Downloader; end
  module Cache; end
  module Installer; end
  module Source; end
  module Runtime; end
  # NOTE: we do NOT define `module Gem` here — it would shadow ::Gem
end
