# frozen_string_literal: true

module Scint
  module SpecUtils
    module_function

    def name(spec)
      spec.respond_to?(:name) ? spec.name : spec[:name]
    end

    def version(spec)
      spec.respond_to?(:version) ? spec.version : spec[:version]
    end

    def platform(spec)
      return spec.platform if spec.respond_to?(:platform)
      return spec[:platform] if spec.is_a?(Hash)
      return nil unless spec.respond_to?(:[])

      spec[:platform]
    rescue NameError, ArgumentError
      nil
    end

    def platform_str(spec)
      platform_value(platform(spec))
    end

    def platform_value(platform)
      value = platform.nil? ? "ruby" : platform.to_s
      value.empty? ? "ruby" : value
    end

    def full_name(spec)
      base = "#{name(spec)}-#{version(spec)}"
      plat = platform_str(spec)
      return base if plat == "ruby"

      "#{base}-#{plat}"
    end

    def full_name_for(name, version, platform = "ruby")
      base = "#{name}-#{version}"
      plat = platform_value(platform)
      return base if plat == "ruby"

      "#{base}-#{plat}"
    end

    def full_key(spec)
      full_key_for(name(spec), version(spec), platform(spec))
    end

    def full_key_for(name, version, platform = "ruby")
      "#{name}-#{version}-#{platform_value(platform)}"
    end
  end
end
