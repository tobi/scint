# frozen_string_literal: true

require_relative "../errors"

module Scint
  module Gemfile
    # Lightweight text editor for common Gemfile dependency updates.
    #
    # Handles single-line `gem` declarations, which is enough for the
    # fast-path workflows used by `scint add` and `scint remove`.
    class Editor
      def initialize(path = "Gemfile")
        @path = path
      end

      def add(name, requirement: nil, group: nil, source: nil, git: nil, path: nil)
        content = read
        line = build_line(
          name,
          requirement: requirement,
          group: group,
          source: source,
          git: git,
          path: path,
        )

        updated = false
        out_lines = content.lines.map do |l|
          if gem_line_for?(l, name)
            updated = true
            "#{line}\n"
          else
            l
          end
        end

        unless updated
          out_lines << "\n" unless out_lines.empty? || out_lines.last.end_with?("\n\n")
          out_lines << "#{line}\n"
        end

        write(out_lines.join)
        updated ? :updated : :added
      end

      def remove(name)
        content = read
        removed = false

        out_lines = content.lines.reject do |line|
          match = gem_line_for?(line, name)
          removed ||= match
          match
        end

        write(out_lines.join)
        removed
      end

      private

      def read
        unless File.exist?(@path)
          raise GemfileError, "Gemfile not found at #{@path}"
        end

        File.read(@path)
      end

      def write(content)
        File.write(@path, content)
      end

      def gem_line_for?(line, name)
        line.match?(/^\s*gem\s+["']#{Regexp.escape(name)}["'](?:\s|,|$)/)
      end

      def build_line(name, requirement:, group:, source:, git:, path:)
        parts = ["gem #{name.inspect}"]
        parts << requirement.inspect if requirement && !requirement.empty?

        opts = []
        opts << "group: :#{group}" if group
        opts << "source: #{source.inspect}" if source
        opts << "git: #{git.inspect}" if git
        opts << "path: #{path.inspect}" if path

        parts << opts.join(", ") unless opts.empty?
        parts.join(", ")
      end
    end
  end
end
