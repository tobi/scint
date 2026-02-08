# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/promoter"

class InstallerPromoterTest < Minitest::Test
  def test_promote_tree_moves_staging_to_target
    with_tmpdir do |dir|
      promoter = Scint::Installer::Promoter.new(root: dir)
      staging = File.join(dir, "staging", "demo")
      target = File.join(dir, "cached", "demo")
      FileUtils.mkdir_p(staging)
      File.write(File.join(staging, "lib.rb"), "")

      result = promoter.promote_tree(staging_path: staging, target_path: target, lock_key: "demo")

      assert_equal :promoted, result
      assert Dir.exist?(target)
      assert File.exist?(File.join(target, "lib.rb"))
    end
  end

  def test_validate_within_root_rejects_escape_paths
    with_tmpdir do |dir|
      promoter = Scint::Installer::Promoter.new(root: dir)
      err = assert_raises(Scint::CacheError) do
        promoter.validate_within_root!(dir, File.join(dir, "..", "escape"), label: "target")
      end
      assert_includes err.message, "Target escapes cache root"
    end
  end

  def test_promote_tree_rejects_staging_outside_root
    with_tmpdir do |dir|
      with_tmpdir do |other|
        promoter = Scint::Installer::Promoter.new(root: dir)
        staging = File.join(other, "staging")
        target = File.join(dir, "cached", "demo")
        FileUtils.mkdir_p(staging)

        assert_raises(Scint::CacheError) do
          promoter.promote_tree(staging_path: staging, target_path: target, lock_key: "demo")
        end
      end
    end
  end
end
