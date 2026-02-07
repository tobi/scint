# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "scint/debug/sampler"

class SamplerTest < Minitest::Test
  def test_sampler_writes_profile_report
    with_tmpdir do |dir|
      out = File.join(dir, "profile.json")
      sampler = Scint::Debug::Sampler.new(path: out, hz: 200, max_depth: 20)

      sampler.start
      # keep VM busy so the sampler captures useful stacks
      10_000.times { "abc".upcase }
      sleep 0.05
      sampler.stop(exit_code: 0)

      assert File.exist?(out)
      data = JSON.parse(File.read(out))
      assert_equal "sampling", data["mode"]
      assert_equal 200, data["sample_hz"]
      assert_equal 0, data["exit_code"]
      assert_operator data["samples"], :>, 0
      assert_operator data["top_frames"].length, :>, 0
    end
  end
end
