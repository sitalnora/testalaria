# frozen_string_literal: true

require "ripper"
require "testalaria/def_index"
require "testalaria/resolver"

module Testalaria
  # Coverage can't see constant *reads*: reading a constant never re-executes its
  # definition, so a changed constant leaves no coverage edge back to the code
  # (and therefore the tests) that depend on it. This index scans source files
  # for constant references and maps each name to the `[file, method]` sites that
  # read it, so selection can add the tests that exercised those sites when a
  # constant changes.
  #
  # Built with the same Ripper + DefIndex/Resolver machinery as the rest of the
  # gem. Matching is by bare constant name — conservative, so `Ns::X` and `X`
  # both match a changed `X` (over-selecting is safe). Pure: sources in, index
  # out; assignment targets and class/module *definitions* are not references.
  class ConstIndex
    # @param sources [Hash{String=>String}] source_file_path => source
    def self.build(sources)
      new(sources)
    end

    def initialize(sources)
      @refs = Hash.new { |h, k| h[k] = [] } # const name => [[file, method], ...]
      sources.each { |file, source| index_file(file, source) }
      @refs.each_value(&:uniq!)
    end

    attr_reader :refs

    # @return [Array<[String, String]>] [file, method] sites reading any name
    def sites_for(names)
      names.flat_map { |n| @refs.key?(n) ? @refs[n] : [] }.uniq
    end

    private

    def index_file(file, source)
      sexp = Ripper.sexp(source)
      return unless sexp

      walk(sexp, file, Resolver.new(DefIndex.build(source)))
    rescue ParseError
      # Unparseable source contributes no references (conservative).
      nil
    end

    def walk(node, file, resolver)
      return unless node.is_a?(Array)

      case node[0]
      when :var_field, :const_path_field, :top_const_field, :const_ref
        return # assignment target / class-module definition — not a read
      when :var_ref, :top_const_ref
        record(node[1], file, resolver)
      when :const_path_ref
        # `A::B::C` — C is the referenced constant; A/B are reads in the scope.
        record(node[2], file, resolver)
        walk(node[1], file, resolver)
        return
      end
      node.each { |child| walk(child, file, resolver) }
    end

    def record(const_node, file, resolver)
      return unless const_node.is_a?(Array) && const_node[0] == :@const

      name = const_node[1]
      line = const_node[2][0]
      @refs[name] << [file, resolver.method_for(line)]
    end
  end
end
