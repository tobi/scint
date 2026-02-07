# frozen_string_literal: true

require_relative "test_helper"

Dir[File.expand_path("**/*_test.rb", __dir__)].sort.each do |path|
  next if path.end_with?("all_test.rb")

  require path
end
