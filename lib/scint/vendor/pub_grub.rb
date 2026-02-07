# frozen_string_literal: true

# Vendored PubGrub loader - loads all PubGrub modules under Scint::PubGrub
require "logger"

module Scint
  module PubGrub
    def self.logger
      @logger ||= ::Logger.new($stderr, level: ::Logger::WARN)
    end

    def self.logger=(logger)
      @logger = logger
    end
  end
end

require_relative "pub_grub/version"
require_relative "pub_grub/version_range"
require_relative "pub_grub/version_union"
require_relative "pub_grub/version_constraint"
require_relative "pub_grub/package"
require_relative "pub_grub/term"
require_relative "pub_grub/assignment"
require_relative "pub_grub/incompatibility"
require_relative "pub_grub/partial_solution"
require_relative "pub_grub/solve_failure"
require_relative "pub_grub/failure_writer"
require_relative "pub_grub/strategy"
require_relative "pub_grub/version_solver"
require_relative "pub_grub/basic_package_source"
require_relative "pub_grub/rubygems"
