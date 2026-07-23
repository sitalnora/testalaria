# frozen_string_literal: true

require "ripper"
require "testalaria/def_index"

module Testalaria
  # Coverage can't see through mocks: a spec that stubs `authenticate_user!`
  # never executes the real method, so no edge is recorded — correctly (the spec
  # can't fail from the real code) but riskily (the composed behaviour changed
  # and the spec is blind). This index scans test files for stubbing constructs
  # so selection can add the blind specs back when a changed method's name or
  # class is stubbed.
  #
  # Built by the same Ripper machinery as DefIndex; conservative by design
  # (name collisions over-select, which is safe). Pure: sources in, index out.
  class StubIndex
    # Calls whose symbol argument names a stubbed method.
    SYMBOL_STUBBERS = %w[receive have_received receive_messages receive_message_chain].freeze
    # Calls whose const argument names a doubled/branched class.
    CONST_DOUBLERS = %w[
      instance_double class_double object_double
      allow_any_instance_of expect_any_instance_of
    ].freeze

    # @param sources [Hash{String=>String}] test_file_path => source
    def self.build(sources)
      new(sources)
    end

    def initialize(sources)
      @symbols = Hash.new { |h, k| h[k] = [] } # method name => [test files]
      @consts = Hash.new { |h, k| h[k] = [] }  # class name  => [test files]
      sources.each do |file, source|
        sexp = Ripper.sexp(source)
        scan(sexp, file) if sexp
      end
      @symbols.each_value(&:uniq!)
      @consts.each_value(&:uniq!)
    end

    attr_reader :symbols, :consts

    # Test files that stub any of the given method names (e.g. "Player#fn_one",
    # "Player.sm") — matched on both the method segment and the class segment.
    def test_files_for(method_names)
      files = []
      method_names.each do |name|
        next if name == DefIndex::TOPLEVEL

        klass, meth = name.split(/[#.]/, 2)
        files.concat(@symbols[meth]) if meth && @symbols.key?(meth)
        files.concat(@consts[klass]) if klass && !klass.empty? && @consts.key?(klass)
      end
      files.uniq
    end

    private

    def scan(node, file)
      return unless node.is_a?(Array)

      name = call_name(node)
      if SYMBOL_STUBBERS.include?(name)
        sym = first_symbol(node)
        @symbols[sym] << file if sym
      elsif CONST_DOUBLERS.include?(name)
        const = first_const(node)
        @consts[const] << file if const
      end

      node.each { |child| scan(child, file) }
    end

    # The invoked method name for a call-shaped node, else nil.
    def call_name(node)
      case node[0]
      when :command then ident_name(node[1])
      when :command_call then ident_name(node[3])
      when :fcall then ident_name(node[1])
      when :call then ident_name(node[3])
      when :method_add_arg, :method_add_block then call_name(node[1])
      end
    end

    def ident_name(node)
      node[1] if node.is_a?(Array) && node[0] == :@ident
    end

    # First symbol literal anywhere in the node's args subtree.
    def first_symbol(node)
      found = nil
      walk_leaves(node) do |n|
        if n[0] == :symbol_literal || n[0] == :symbol
          ident = deep_find(n) { |x| x.is_a?(Array) && x[0] == :@ident }
          found ||= ident && ident[1]
        end
      end
      found
    end

    def first_const(node)
      c = deep_find(node) { |x| x.is_a?(Array) && x[0] == :@const }
      c && c[1]
    end

    def walk_leaves(node, &block)
      return unless node.is_a?(Array)

      block.call(node) if node[0].is_a?(Symbol)
      node.each { |child| walk_leaves(child, &block) }
    end

    def deep_find(node, &block)
      return node if block.call(node)
      return nil unless node.is_a?(Array)

      node.each do |child|
        next unless child.is_a?(Array)

        found = deep_find(child, &block)
        return found if found
      end
      nil
    end
  end
end
