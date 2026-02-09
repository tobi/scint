# frozen_string_literal: true

require_relative "scint/version"

module Scint
  # Color support: respects NO_COLOR (https://no-color.org) and TERM=dumb.
  COLOR = !ENV.key?("NO_COLOR") && ENV["TERM"] != "dumb" && $stderr.tty?

  GREEN  = COLOR ? "\e[32m" : ""
  RED    = COLOR ? "\e[31m" : ""
  YELLOW = COLOR ? "\e[33m" : ""
  BLUE   = COLOR ? "\e[34m" : ""
  BOLD   = COLOR ? "\e[1m"  : ""
  DIM    = COLOR ? "\e[2m"  : ""
  RESET  = COLOR ? "\e[0m"  : ""

  # XDG-based cache root
  def self.cache_root
    @cache_root ||= default_cache_root
  end

  def self.cache_root=(path)
    @cache_root = path
  end

  def self.default_cache_root
    explicit = ENV["SCINT_CACHE"]
    return File.expand_path(explicit) unless explicit.nil? || explicit.empty?

    File.join(
      ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")),
      "scint"
    )
  end
  private_class_method :default_cache_root

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
  autoload :CLI,         "scint/cli"
  autoload :Scheduler,   "scint/scheduler"
  autoload :WorkerPool,  "scint/worker_pool"
  autoload :Progress,    "scint/progress"
  autoload :FS,          "scint/fs"
  autoload :Platform,    "scint/platform"
  autoload :SpecUtils,   "scint/spec_utils"

  # Errors
  autoload :BundlerError,        "scint/errors"
  autoload :GemfileError,        "scint/errors"
  autoload :LockfileError,       "scint/errors"
  autoload :ResolveError,        "scint/errors"
  autoload :NetworkError,        "scint/errors"
  autoload :InstallError,        "scint/errors"
  autoload :ExtensionBuildError, "scint/errors"
  autoload :PermissionError,     "scint/errors"
  autoload :PlatformError,       "scint/errors"
  autoload :CacheError,          "scint/errors"

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
