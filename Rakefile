# frozen_string_literal: true

require "rake/testtask"
require "rubygems"

desc "Run test suite"
Rake::TestTask.new(:test) do |t|
  t.libs = ["test"]
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/all_test.rb")
end

desc "Build scint gem package"
task :build do
  sh "gem build scint.gemspec"
end

desc "Build and install scint gem locally"
task install: :build do
  spec = Gem::Specification.load("scint.gemspec")
  gem_file = "#{spec.name}-#{spec.version}.gem"
  sh "gem install --local ./#{gem_file} --no-document"
end

namespace :install do
  desc "Symlink scint into gem dir for development (edits take effect immediately)"
  task :link do
    require "fileutils"
    spec = Gem::Specification.load("scint.gemspec")
    gem_dir = Gem.dir
    target = File.join(gem_dir, "gems", "#{spec.name}-#{spec.version}")
    spec_target = File.join(gem_dir, "specifications", "#{spec.name}-#{spec.version}.gemspec")
    bin_dir = File.join(gem_dir, "bin")
    source = File.expand_path(".", __dir__)

    # Remove previous install (real dir or stale symlink)
    if File.symlink?(target) || File.directory?(target)
      FileUtils.rm_rf(target)
    end

    # Symlink gem dir → project root
    FileUtils.ln_s(source, target, verbose: true)

    # Write a stub gemspec that points at the symlinked path
    File.write(spec_target, spec.to_ruby)
    puts "Wrote #{spec_target}"

    # Symlink each executable into gem bin dir
    FileUtils.mkdir_p(bin_dir)
    spec.executables.each do |exe|
      exe_src = File.join(source, spec.bindir, exe)
      exe_dst = File.join(bin_dir, exe)
      FileUtils.rm_f(exe_dst)
      FileUtils.ln_s(exe_src, exe_dst, verbose: true)
    end

    puts "Linked #{spec.name}-#{spec.version} → #{source}"
  end
end

task default: :test
