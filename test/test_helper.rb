# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_filter "lib/scint/vendor/"
  add_filter "lib/bundler.rb"
  add_filter "lib/bundler/"
  add_filter "lib/scint/version.rb"
  enable_coverage :branch
  track_files "lib/**/*.rb"
end

require "minitest/autorun"

# Report slow tests at the end of the run.
SLOW_THRESHOLD = ENV.fetch("SLOW_THRESHOLD", "0.5").to_f
SLOW_RESULTS = []

module SlowTestTracker
  def record(result)
    super
    SLOW_RESULTS << result if result.time > SLOW_THRESHOLD
  end

  def report
    super

    return if SLOW_RESULTS.empty?
    SLOW_RESULTS.sort_by! { |r| -r.time }
    io.puts
    io.puts "\e[33mSlow tests (>#{SLOW_THRESHOLD}s):\e[0m"
    SLOW_RESULTS.each do |r|
      io.printf "  %6.2fs  %s#%s\n", r.time, r.class_name, r.name
    end
  end
end

Minitest::CompositeReporter.prepend(SlowTestTracker)
require "tmpdir"
require "fileutils"
require "stringio"
require "zlib"
require "rubygems/package"
require "digest"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "scint"
require "scint/errors"
require "scint/fs"

module LegacyStub
  def stub(method_name, value = nil)
    sc = singleton_class
    own_method = sc.instance_methods(false).include?(method_name) || sc.private_instance_methods(false).include?(method_name)
    had_method = sc.method_defined?(method_name) || sc.private_method_defined?(method_name)
    original = method(method_name) if own_method && had_method

    sc.send(:remove_method, method_name) if own_method
    sc.send(:define_method, method_name) do |*args, **kwargs, &block|
      if value.respond_to?(:call)
        value.call(*args, **kwargs, &block)
      else
        value
      end
    end

    yield
  ensure
    if sc.instance_methods(false).include?(method_name) || sc.private_instance_methods(false).include?(method_name)
      sc.send(:remove_method, method_name)
    end
    sc.send(:define_method, method_name, original) if own_method && original
  end
end

Object.include(LegacyStub)

module ScintTestHelpers
  def capture_io
    old_out, old_err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = old_out, old_err
  end

  def with_tmpdir(prefix = "scint-test")
    Dir.mktmpdir(prefix) do |dir|
      yield dir
    end
  end

  def with_cwd(path)
    prev = Dir.pwd
    Dir.chdir(path)
    yield
  ensure
    Dir.chdir(prev)
  end

  def with_env(key, value)
    old = ENV[key]
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
    yield
  ensure
    if old.nil?
      ENV.delete(key)
    else
      ENV[key] = old
    end
  end

  def fake_spec(name:, version:, platform: "ruby", source: "https://rubygems.org", has_extensions: false, dependencies: [])
    Scint::ResolvedSpec.new(
      name: name,
      version: version,
      platform: platform,
      dependencies: dependencies,
      source: source,
      has_extensions: has_extensions,
      remote_uri: nil,
      checksum: nil,
    )
  end

  def ruby_bundle_dir(bundle_path)
    File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
  end

  def assert_hardlinked(path_a, path_b)
    assert_equal File.stat(path_a).ino, File.stat(path_b).ino
  end

  def make_tar(entries)
    io = StringIO.new("".b)
    Gem::Package::TarWriter.new(io) do |tar|
      entries.each do |entry|
        case entry[:type]
        when :file
          content = entry.fetch(:content)
          tar.add_file_simple(entry.fetch(:name), entry.fetch(:mode, 0o644), content.bytesize) do |f|
            f.write(content)
          end
        when :dir
          tar.mkdir(entry.fetch(:name), entry.fetch(:mode, 0o755))
        when :symlink
          tar.add_symlink(entry.fetch(:name), entry.fetch(:target), entry.fetch(:mode, 0o777))
        else
          raise "unknown tar entry type: #{entry[:type].inspect}"
        end
      end
    end
    io.string
  end

  def gzip(data)
    io = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(io)
    writer.write(data)
    writer.close
    io.string
  end

  def create_fake_gem(path, name:, version:, platform: Gem::Platform::RUBY, files: {}, require_paths: ["lib"])
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = Gem::Version.new(version)
      s.platform = platform
      s.authors = ["scint-test"]
      s.summary = "test gem"
      s.files = files.keys
      s.require_paths = require_paths
    end

    metadata_gz = gzip(spec.to_yaml)

    data_entries = files.map do |file_path, content|
      { type: :file, name: file_path, content: content }
    end
    data_tar_gz = gzip(make_tar(data_entries))

    gem_entries = [
      { type: :file, name: "metadata.gz", content: metadata_gz },
      { type: :file, name: "data.tar.gz", content: data_tar_gz },
    ]

    File.binwrite(path, make_tar(gem_entries))
    spec
  end

  def http_response(klass, body: "", headers: {})
    code = if klass.const_defined?(:CODE)
             klass::CODE
           else
             case klass.name
             when "Net::HTTPFound" then "302"
             when "Net::HTTPPartialContent" then "206"
             when "Net::HTTPNotModified" then "304"
             when "Net::HTTPNotFound" then "404"
             else "200"
             end
           end

    message = klass.const_defined?(:MESSAGE) ? klass::MESSAGE : "OK"
    response = klass.new("1.1", code, message)
    headers.each { |k, v| response[k] = v }
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    response
  end
end

class Minitest::Test
  include ScintTestHelpers

  def before_setup
    super
    # Reset memoized state so tests don't leak into each other.
    Scint::FS.instance_variable_set(:@copy_strategy, nil) if defined?(Scint::FS)
    Scint.cache_root = nil
  end
end
