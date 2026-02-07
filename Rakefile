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

task default: :test
