# frozen_string_literal: true

module Bundler2
  class BundlerError < StandardError
    def status_code
      1
    end
  end

  class GemfileError < BundlerError
    def status_code
      4
    end
  end

  class LockfileError < BundlerError
    def status_code
      5
    end
  end

  class ResolveError < BundlerError
    def status_code
      6
    end
  end

  class NetworkError < BundlerError
    def status_code
      7
    end
  end

  class InstallError < BundlerError
    def status_code
      8
    end
  end

  class ExtensionBuildError < InstallError
    def status_code
      9
    end
  end

  class PermissionError < BundlerError
    def status_code
      10
    end
  end

  class PlatformError < BundlerError
    def status_code
      11
    end
  end

  class CacheError < BundlerError
    def status_code
      12
    end
  end
end
