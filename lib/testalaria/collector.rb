# frozen_string_literal: true

require "testalaria/resolver"
require "testalaria/def_index"

module Testalaria
  # Photographs Coverage's line counters before and after each example; lines
  # whose counts moved belong to that example (earlier executions appear in both
  # photos and cancel out). Raw lines are immediately resolved to method names
  # via a DefIndex of the file as it is on disk during the run, and the line
  # numbers are discarded — names survive edits, lines don't.
  #
  # Transitive dependencies flatten here for free: a test that reaches a method
  # through four layers still executed its lines, so it gets a *direct* entry —
  # no call-graph traversal ever exists.
  class Collector
    # @param coverage [CoverageSource] the coverage seam
    # @param root [String] project root; files outside it are ignored
    # @param ignore [Array<String>] leading path fragments to drop (relative),
    #   e.g. test/spec dirs whose own execution is not a source edge
    def initialize(coverage:, root: Dir.pwd, ignore: %w[spec/ test/])
      @coverage = coverage
      @root = File.expand_path(root)
      @ignore = ignore
      @def_index_cache = {}
      @before = nil
    end

    def start_example
      @before = @coverage.peek
    end

    # @return [Hash{String=>Array<String>}] relative_file => sorted method names
    def finish_example
      after = @coverage.peek
      to_methods(diff(@before || {}, after))
    end

    # The cumulative set of project source lines executed so far, as
    # { relative_file => [line, ...] } — used for per-PR diff coverage. Reads
    # the running total (any line with a count > 0 ran during this process).
    def executed_lines
      @coverage.peek.each_with_object({}) do |(abs, counts), acc|
        next unless in_project?(abs)

        rel = relative(abs)
        next if ignored?(rel)

        lines = counts.each_index.select { |i| counts[i].to_i.positive? }.map { |i| i + 1 }
        acc[rel] = lines unless lines.empty?
      end
    end

    private

    # { abs_file => [line, ...] } for lines whose count increased.
    def diff(before, after)
      result = {}
      after.each do |file, after_counts|
        next unless in_project?(file)

        before_counts = before[file] || []
        lines = moved_lines(before_counts, after_counts)
        result[file] = lines unless lines.empty?
      end
      result
    end

    def moved_lines(before_counts, after_counts)
      lines = []
      after_counts.each_with_index do |count, idx|
        next if count.nil?

        before = before_counts[idx] || 0
        lines << (idx + 1) if count > before
      end
      lines
    end

    def to_methods(touched)
      touched.each_with_object({}) do |(abs, lines), acc|
        rel = relative(abs)
        next if ignored?(rel)

        acc[rel] = resolver_for(abs).names_for(lines)
      end
    end

    def resolver_for(abs)
      di = (@def_index_cache[abs] ||= build_def_index(abs))
      Resolver.new(di)
    end

    def build_def_index(abs)
      DefIndex.build(File.read(abs))
    rescue ParseError, Errno::ENOENT
      # Unparseable/vanished during the run: attribute everything to toplevel
      # rather than losing the edge. A single-entry table covering all lines.
      DefIndex.build("")
    end

    def in_project?(file)
      file.start_with?(@root) && !file.include?("/gems/") && !file.include?("/vendor/")
    end

    def ignored?(rel)
      @ignore.any? { |prefix| rel.start_with?(prefix) }
    end

    def relative(abs)
      abs.start_with?("#{@root}/") ? abs.sub("#{@root}/", "") : abs
    end
  end
end
