module Scint::PubGrub
  VERSION = if defined?(::Scint::VERSION)
    ::Scint::VERSION
  else
    File.read(File.expand_path("../../../../VERSION", __dir__)).strip
  end
end
