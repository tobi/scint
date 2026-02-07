# frozen_string_literal: true

require_relative "lib/scint"

Gem::Specification.new do |spec|
  spec.name = "scint"
  spec.version = Scint::VERSION
  spec.authors = ["Scint Contributors"]
  spec.email = ["maintainers@example.com"]

  spec.summary = "Fast Bundler-compatible installer with phased parallel execution"
  spec.description = "Scint is a Bundler-compatible dependency installer that uses a scheduler-driven, phase-oriented architecture to maximize parallel throughput while preserving Gemfile/Gemfile.lock behavior."
  spec.homepage = "https://example.com/scint"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.glob("{bin,lib}/**/*").select { |path| File.file?(path) }
  spec.files += %w[README.md FEATURES.md]
  spec.files.uniq!

  spec.bindir = "bin"
  spec.executables = ["scint"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
end
