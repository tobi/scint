# frozen_string_literal: true

require "rubygems/package"
require "zlib"
require "stringio"
require_relative "../fs"

module Scint
  module GemPkg
    class Package
      # Read gemspec from a .gem file without full extraction.
      # Returns a Gem::Specification.
      def read_metadata(gem_path)
        File.open(gem_path, "rb") do |io|
          tar = ::Gem::Package::TarReader.new(io)
          tar.each do |entry|
            if entry.full_name == "metadata.gz"
              gz = Zlib::GzipReader.new(StringIO.new(entry.read))
              return ::Gem::Specification.from_yaml(gz.read)
            end
          end
        end
        raise InstallError, "No metadata.gz found in #{gem_path}"
      end

      # Single-pass extraction: reads the .gem TAR once, extracts both
      # metadata.gz (gemspec) and data.tar.gz (files) in one pass.
      # Returns { gemspec: Gem::Specification, extracted_path: dest_dir }
      def extract(gem_path, dest_dir)
        FS.mkdir_p(dest_dir)
        gemspec = nil
        data_tar_gz = nil

        File.open(gem_path, "rb") do |io|
          tar = ::Gem::Package::TarReader.new(io)
          tar.each do |entry|
            case entry.full_name
            when "metadata.gz"
              gz = Zlib::GzipReader.new(StringIO.new(entry.read))
              gemspec = ::Gem::Specification.from_yaml(gz.read)
            when "data.tar.gz"
              # Write data.tar.gz to a temp file for extraction
              tmp = File.join(dest_dir, ".data.tar.gz.tmp")
              File.open(tmp, "wb") { |f| f.write(entry.read) }
              data_tar_gz = tmp
            end
          end
        end

        raise InstallError, "No metadata.gz in #{gem_path}" unless gemspec

        if data_tar_gz
          Extractor.new.extract(data_tar_gz, dest_dir)
          File.delete(data_tar_gz) if File.exist?(data_tar_gz)
        end

        { gemspec: gemspec, extracted_path: dest_dir }
      end
    end
  end
end
