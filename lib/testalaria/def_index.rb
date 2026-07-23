# frozen_string_literal: true

require "ripper"

module Testalaria
  # Parses a Ruby source string into a table of `"Nesting#method" => line_range`
  # entries, plus a `(toplevel)` bucket for class-body code. Both ends of the
  # system go through this one table: collection resolves Coverage-reported
  # lines to names to *write* the map; selection resolves git-hunk lines to
  # names to *read* it. One parser, one table shape — writer and reader can
  # never disagree about which method a line belongs to.
  #
  # Uses stdlib Ripper on every supported Ruby (2.7+). Prism (bundled on 3.3+)
  # would give exact end-lines directly; it is a future optimization behind the
  # same public interface. The subtree-max end-line computed here slightly
  # undershoots the literal `end` keyword, which is safe by construction:
  # Coverage only reports *executable* lines and `end` is not one.
  class DefIndex
    TOPLEVEL = "(toplevel)"

    # Names that mark a file as containing dynamically-defined methods we can't
    # statically key on. Presence flips `dynamic?`, which the selector uses to
    # escalate rather than silently mis-resolve.
    DYNAMIC_METHODS = %w[
      define_method class_eval module_eval instance_eval class_exec instance_exec
    ].freeze

    Entry = Struct.new(:name, :range)

    # Sorted [Entry, ...] by range start then name. Non-overlapping.
    attr_reader :entries

    # @param source [String] Ruby source
    # @raise [ParseError] on unparseable source (selection escalates the file)
    def self.build(source)
      new(source)
    end

    def initialize(source)
      @entries = []
      @dynamic = false
      sexp = Ripper.sexp(source)
      raise ParseError, "source did not parse" if sexp.nil?

      walk(sexp, [], singleton: false)
      @entries.sort_by! { |e| [e.range.begin, e.name] }
    end

    def dynamic?
      @dynamic
    end

    private

    def walk(node, stack, singleton:)
      return unless node.is_a?(Array)

      case node[0]
      when :class
        # [:class, const, superclass_or_nil, bodystmt]
        walk(node[3], stack + [const_name(node[1])], singleton: false)
      when :module
        # [:module, const, bodystmt]
        walk(node[2], stack + [const_name(node[1])], singleton: false)
      when :sclass
        # class << self : defs inside are singleton methods on the nesting
        walk(node[2], stack, singleton: true)
      when :def
        # [:def, ident, params, bodystmt]
        record_def(node[1], node, stack, singleton: singleton)
      when :defs
        # [:defs, target, period, ident, params, bodystmt] -> always singleton
        record_def(node[3], node, stack, singleton: true)
      else
        flag_dynamic(node)
        node.each { |child| walk(child, stack, singleton: singleton) }
      end
    end

    def record_def(ident, node, stack, singleton:)
      name = ident[1]
      start_line = ident[2][0]
      nesting = stack.join("::")
      sep = singleton ? "." : "#"
      @entries << Entry.new("#{nesting}#{sep}#{name}", start_line..max_line(node))
      # A def nested inside a def can't be statically keyed on reliably.
      @dynamic = true if nested_def?(node[2..])
    end

    # Const name from a const_ref / const_path_ref / var_ref, joined with "::".
    def const_name(node)
      return "<anon>" unless node.is_a?(Array)

      case node[0]
      when :const_ref, :top_const_ref then node[1][1]
      when :const_path_ref then "#{const_name(node[1])}::#{node[2][1]}"
      when :var_ref then node[1][1]
      when :@const then node[1]
      else "<anon>"
      end
    end

    # Largest line number anywhere in the node's subtree. Position pairs are the
    # only bare [Integer, Integer] arrays Ripper emits, so collecting them is
    # unambiguous.
    def max_line(node)
      max = 0
      stack = [node]
      until stack.empty?
        cur = stack.pop
        next unless cur.is_a?(Array)

        if cur.length == 2 && cur[0].is_a?(Integer) && cur[1].is_a?(Integer)
          max = cur[0] if cur[0] > max
        else
          cur.each { |c| stack.push(c) if c.is_a?(Array) }
        end
      end
      max
    end

    def flag_dynamic(node)
      @dynamic = true if node[0] == :@ident && DYNAMIC_METHODS.include?(node[1])
    end

    def nested_def?(node)
      return false unless node.is_a?(Array)
      return true if %i[def defs].include?(node[0])

      node.any? { |c| nested_def?(c) }
    end
  end
end
