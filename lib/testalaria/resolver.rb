# frozen_string_literal: true

require "testalaria/def_index"

module Testalaria
  # Resolves line numbers to method names through a DefIndex. Pure: a table and
  # a list of lines in, a sorted list of names out. Used symmetrically by
  # collection (Coverage lines -> names, to write the map) and selection
  # (git-hunk lines -> names, to read it).
  class Resolver
    def initialize(def_index)
      @def_index = def_index
    end

    # @return [String] enclosing method name, or DefIndex::TOPLEVEL
    def method_for(line)
      @def_index.entries.each do |entry|
        return entry.name if entry.range.cover?(line)
      end
      DefIndex::TOPLEVEL
    end

    # @param lines [Enumerable<Integer>]
    # @return [Array<String>] unique, sorted method names (incl. TOPLEVEL)
    def names_for(lines)
      lines.map { |line| method_for(line) }.uniq.sort
    end
  end
end
