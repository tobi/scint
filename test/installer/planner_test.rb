# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "scint/installer/planner"
require "scint/cache/layout"
require "scint/cache/validity"
require "scint/source/path"

class PlannerTest < Minitest::Test
  Spec = Struct.new(:name, :version, :platform, :has_extensions, :size, :source, keyword_init: true)

  def write_cached_entry(layout, spec, manifest: true, manifest_version: 1, ext_name: nil)
    cached_dir = layout.cached_path(spec)
    FileUtils.mkdir_p(cached_dir)
    FileUtils.mkdir_p(File.dirname(layout.cached_spec_path(spec)))
    File.binwrite(layout.cached_spec_path(spec), Marshal.dump({ "name" => spec.name }))

    if manifest
      data = {
        "version" => manifest_version,
        "full_name" => layout.full_name(spec),
        "abi" => Scint::Platform.abi_key,
        "source" => { "type" => "rubygems", "uri" => "https://rubygems.org" },
        "files" => [],
        "build" => { "extensions" => false },
      }
      File.write(layout.cached_manifest_path(spec), JSON.generate(data))
    end

    if ext_name
      ext_dir = File.join(cached_dir, "ext", ext_name)
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
    end

    cached_dir
  end

  def write_ext_complete(layout, spec)
    ext_dir = layout.ext_path(spec)
    FileUtils.mkdir_p(ext_dir)
    File.write(File.join(ext_dir, "gem.build_complete"), "")
  end

  def test_plan_one_marks_skip_when_already_installed
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      gem_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "gems", "rack-2.2.8")
      spec_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "rack-2.2.8.gemspec"), "Gem::Specification.new do |s| end\n")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :skip, entry.action
      assert_equal gem_dir, entry.gem_path
    end
  end

  def test_plan_one_marks_build_ext_when_installed_but_extension_link_missing
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "bootsnap", version: "1.22.0", platform: "ruby", has_extensions: false)

      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      gem_dir = File.join(ruby_dir, "gems", "bootsnap-1.22.0")
      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "bootsnap-1.22.0.gemspec"), "Gem::Specification.new do |s| end\n")

      ext_src = File.join(layout.extracted_path(spec), "ext", "bootsnap")
      FileUtils.mkdir_p(ext_src)
      File.write(File.join(ext_src, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_link_when_installed_extension_missing_but_global_ext_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "bootsnap", version: "1.22.0", platform: "ruby", has_extensions: false)

      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      gem_dir = File.join(ruby_dir, "gems", "bootsnap-1.22.0")
      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "bootsnap-1.22.0.gemspec"), "Gem::Specification.new do |s| end\n")

      ext_src = File.join(layout.extracted_path(spec), "ext", "bootsnap")
      FileUtils.mkdir_p(ext_src)
      File.write(File.join(ext_src, "extconf.rb"), "")

      cached_ext = layout.ext_path(spec)
      FileUtils.mkdir_p(cached_ext)
      File.write(File.join(cached_ext, "gem.build_complete"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_one_does_not_skip_when_gemspec_missing
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      gem_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0", "gems", "rack-2.2.8")
      FileUtils.mkdir_p(gem_dir)

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      refute_equal :skip, entry.action
    end
  end

  def test_plan_one_marks_link_when_cached_entry_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      cached_dir = write_cached_entry(layout, spec)

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
      assert_equal cached_dir, entry.cached_path
    end
  end

  def test_plan_one_uses_legacy_cached_entry_without_manifest
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "rack", version: "2.2.8", platform: "ruby", has_extensions: false)

      cached_dir = write_cached_entry(layout, spec, manifest: false)
      telemetry = Scint::Cache::Telemetry.new

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout, telemetry: telemetry).first
      assert_equal :link, entry.action
      assert_equal cached_dir, entry.cached_path

      assert_equal 1, telemetry.counts["cache.manifest.missing"]
    end
  end

  def test_plan_one_marks_link_when_no_ext_directory_exists
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      write_cached_entry(layout, spec)

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_one_marks_build_ext_when_ext_directory_exists_and_not_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_link_when_extensions_cached
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "ffi", version: "1.17.0", platform: "ruby", has_extensions: true)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "ffi_c")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
      FileUtils.mkdir_p(layout.ext_path(spec))
      File.write(File.join(layout.ext_path(spec), "gem.build_complete"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_one_marks_build_ext_when_native_dir_exists_even_if_flag_false
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "bootsnap", version: "1.22.0", platform: "ruby", has_extensions: false)

      ext_dir = File.join(layout.extracted_path(spec), "ext", "bootsnap")
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :build_ext, entry.action
    end
  end

  def test_plan_one_marks_link_for_platform_gem_with_matching_prebuilt_ruby_dir
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(name: "sqlite3", version: "2.0.0", platform: "x86_64-linux", has_extensions: true)

      ruby_minor = RUBY_VERSION[/\d+\.\d+/]
      ext_dir = File.join(layout.extracted_path(spec), "ext", "sqlite3")
      prebuilt_dir = File.join(layout.extracted_path(spec), "lib", "sqlite3", ruby_minor)
      FileUtils.mkdir_p(ext_dir)
      File.write(File.join(ext_dir, "extconf.rb"), "")
      FileUtils.mkdir_p(prebuilt_dir)

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :link, entry.action
    end
  end

  def test_plan_sorts_downloads_by_estimated_size_before_rest
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))

      big = Spec.new(name: "big", version: "1.0.0", platform: "ruby", has_extensions: false, size: 50)
      small = Spec.new(name: "small", version: "1.0.0", platform: "ruby", has_extensions: false, size: 10)
      cached = Spec.new(name: "cached", version: "1.0.0", platform: "ruby", has_extensions: false, size: 100)

      write_cached_entry(layout, cached)

      entries = Scint::Installer::Planner.plan([small, cached, big], bundle_path, layout)

      assert_equal %i[download download link], entries.map(&:action)
      assert_equal ["big", "small", "cached"], entries.map { |e| e.spec.name }
    end
  end

  def test_plan_one_marks_link_for_relative_local_path_source
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "components", "crm")
        FileUtils.mkdir_p(local_dir)

        spec = Spec.new(
          name: "crm",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: "components/crm",
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :link, entry.action
        assert_equal File.realpath(local_dir), File.realpath(entry.cached_path)
      end
    end
  end

  def test_plan_one_marks_build_ext_for_relative_local_path_source_with_extconf
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "components", "native")
        ext_dir = File.join(local_dir, "ext", "native")
        FileUtils.mkdir_p(ext_dir)
        File.write(File.join(ext_dir, "extconf.rb"), "")

        spec = Spec.new(
          name: "native",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: "components/native",
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :build_ext, entry.action
        assert_equal File.realpath(local_dir), File.realpath(entry.cached_path)
      end
    end
  end

  def test_plan_one_marks_builtin_when_scint_not_installed
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(
        name: "scint",
        version: Scint::VERSION,
        platform: "ruby",
        has_extensions: false,
        source: "scint (built-in)",
      )

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :builtin, entry.action
    end
  end

  def test_plan_one_marks_skip_for_installed_builtin_scint
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = Spec.new(
        name: "scint",
        version: Scint::VERSION,
        platform: "ruby",
        has_extensions: false,
        source: "scint (built-in)",
      )

      ruby_dir = File.join(bundle_path, "ruby", RUBY_VERSION.split(".")[0, 2].join(".") + ".0")
      gem_dir = File.join(ruby_dir, "gems", "scint-#{Scint::VERSION}")
      spec_dir = File.join(ruby_dir, "specifications")
      FileUtils.mkdir_p(gem_dir)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "scint-#{Scint::VERSION}.gemspec"), "Gem::Specification.new do |s| end\n")

      entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
      assert_equal :skip, entry.action
    end
  end

  def test_plan_one_marks_link_for_source_with_path_method
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "vendor", "mygem")
        FileUtils.mkdir_p(local_dir)

        # Source object with `path` method (hits line 123)
        source = Object.new
        source.define_singleton_method(:path) { Pathname.new("vendor/mygem") }
        source.define_singleton_method(:to_s) { "vendor/mygem" }

        spec = Spec.new(
          name: "mygem",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: source,
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :link, entry.action
      end
    end
  end

  def test_plan_one_marks_link_for_path_source_via_uri
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        local_dir = File.join(dir, "vendor", "mygem")
        FileUtils.mkdir_p(local_dir)

        # Source::Path-like object with `uri` method and class name ending in "::Path" (line 125)
        source = Scint::Source::Path.new(path: "vendor/mygem")

        spec = Spec.new(
          name: "mygem",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: source,
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :link, entry.action
      end
    end
  end

  def test_plan_one_uses_path_source_subdir_for_monorepo_gem
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        repo_root = File.join(dir, "rails")
        subdir = File.join(repo_root, "actionpack")
        FileUtils.mkdir_p(subdir)
        File.write(File.join(subdir, "actionpack.gemspec"), "Gem::Specification.new do |s| end\n")

        source = Scint::Source::Path.new(path: "rails", glob: "{,*/}*.gemspec")
        spec = Spec.new(
          name: "actionpack",
          version: "8.2.0.alpha",
          platform: "ruby",
          has_extensions: false,
          source: source,
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal :link, entry.action
        assert_equal File.realpath(subdir), File.realpath(entry.cached_path)
      end
    end
  end

  def test_plan_one_resolves_dot_path_source_to_component_subdir
    with_tmpdir do |dir|
      with_cwd(dir) do
        bundle_path = File.join(dir, ".bundle")
        layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
        subdir = File.join(dir, "actionpack")
        FileUtils.mkdir_p(subdir)
        File.write(File.join(subdir, "actionpack.gemspec"), "Gem::Specification.new do |s| end\n")

        source = Scint::Source::Path.new(path: ".", glob: "{,*/}*.gemspec")
        spec = Spec.new(
          name: "actionpack",
          version: "8.2.0.alpha",
          platform: "ruby",
          has_extensions: false,
          source: source,
        )

        entry = Scint::Installer::Planner.plan([spec], bundle_path, layout).first
        assert_equal File.realpath(subdir), File.realpath(entry.cached_path)
        refute_equal File.realpath(dir), File.realpath(entry.cached_path)
      end
    end
  end

  def test_local_source_path_with_hash_spec_source_key
    with_tmpdir do |dir|
      with_cwd(dir) do
        local_dir = File.join(dir, "vendor", "hashgem")
        FileUtils.mkdir_p(local_dir)

        # Use a hash-like spec that responds to :source by returning a value
        # via the hash key (line 117: spec[:source])
        # We need a spec that does NOT respond_to?(:source) to hit line 117.
        # Actually, looking at lines 112-118:
        #   if spec.respond_to?(:source) => spec.source
        #   else => spec[:source]
        # Our Spec struct responds to :source, so we need a plain hash.
        # But plan_one also calls spec.name etc. So we'd need a special object.
        # The local_source_path method is private, so let's call it directly
        # with a hash that has [:source] but no .source method.
        hash_spec = { source: "vendor/hashgem", name: "hashgem", version: "0.1.0" }

        result = Scint::Installer::Planner.send(:local_source_path, hash_spec)
        assert_equal File.realpath(local_dir), File.realpath(result)
      end
    end
  end

  def test_local_source_path_with_uri_path_class
    with_tmpdir do |dir|
      with_cwd(dir) do
        local_dir = File.join(dir, "vendor", "urigem")
        FileUtils.mkdir_p(local_dir)

        # Create a source object with .uri method (no .path method)
        # whose class name ends in "::Path" to hit lines 124-125
        path_class = Class.new do
          def initialize(uri_val)
            @uri_val = uri_val
          end

          def uri
            @uri_val
          end

          def to_s
            "custom path source"
          end

          # Make class name end with ::Path
          def self.name
            "Custom::Source::Path"
          end
        end

        source = path_class.new("vendor/urigem")

        spec = Spec.new(
          name: "urigem",
          version: "0.1.0",
          platform: "ruby",
          has_extensions: false,
          source: source,
        )

        result = Scint::Installer::Planner.send(:local_source_path, spec)
        assert_equal File.realpath(local_dir), File.realpath(result)
      end
    end
  end

  def test_plan_orders_builtin_before_downloads_and_other_entries
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))

      builtin = Spec.new(
        name: "scint",
        version: Scint::VERSION,
        platform: "ruby",
        has_extensions: false,
        source: "scint (built-in)",
      )
      big = Spec.new(name: "big", version: "1.0.0", platform: "ruby", has_extensions: false, size: 100)
      small = Spec.new(name: "small", version: "1.0.0", platform: "ruby", has_extensions: false, size: 10)
      cached = Spec.new(name: "cached", version: "1.0.0", platform: "ruby", has_extensions: false)
      write_cached_entry(layout, cached)

      entries = Scint::Installer::Planner.plan([small, cached, builtin, big], bundle_path, layout)

      assert_equal %i[builtin download download link], entries.map(&:action)
      assert_equal ["scint", "big", "small", "cached"], entries.map { |e| e.spec.name }
    end
  end
end
