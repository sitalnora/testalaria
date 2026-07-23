# frozen_string_literal: true

require "psych"
require "set"
require "testalaria/map"
require "testalaria/resolver"
require "testalaria/rot_lint"

module Testalaria
  # Assembles the PR analysis report from data the flow already produced. Pure:
  # a Flow::Outcome in, an artifact hash / terminal string out. Emits the four
  # sections: things tested, possible affected areas, new code not tested, and
  # the selection trace (always in the artifact; terminal only under VERBOSE).
  class Report
    ARTIFACT_VERSION = 1

    def initialize(outcome, head: nil)
      @outcome = outcome
      @selection = outcome.selection
      @map = outcome.map_after || {}
      @executed_lines = outcome.executed_lines
      @changed_sources = outcome.changed_sources
      @head = head
    end

    def artifact
      {
        "version" => ARTIFACT_VERSION,
        "map_commit" => @map[:commit],
        "head" => @head,
        "selection" => selection_summary,
        "tested" => tested,
        "affected" => affected,
        "untested_new_code" => untested_new_code,
        "nondeterminism" => nondeterminism,
        "selection_trace" => selection_trace
      }
    end

    def artifact_yaml
      Psych.dump(artifact)
    end

    def terminal(verbose: false)
      lines = []
      lines << "testalaria: #{summary_line}"
      affected["uncovered_changed_files"].each do |f|
        lines << "  exposed (no known coverage): #{f}"
      end
      @selection.escalations.each do |esc|
        lines << "  escalated #{esc.file} -> #{esc.cause}"
      end
      untested_new_code.each do |u|
        lines << "  untested new code: #{u['method']} (#{u['file']})"
      end
      lines.concat(trace_lines) if verbose
      lines.join("\n")
    end

    private

    def summary_line
      if @outcome.full_run
        "full run triggered by #{@outcome.trigger}"
      else
        "#{examples_selected} of #{total_known_examples} examples selected"
      end
    end

    def selection_summary
      {
        "total_known_examples" => total_known_examples,
        "examples_selected" => examples_selected,
        "full_run_triggered" => @outcome.full_run || false,
        "trigger" => @outcome.trigger
      }
    end

    def total_known_examples
      Map.example_keys(@map).size
    end

    def examples_selected
      @selection.example_reasons.size
    end

    # file => [examples it selected]
    def tested
      out = Hash.new { |h, k| h[k] = [] }
      @selection.example_reasons.each do |example, reasons|
        reasons.each { |r| out[r.file] << example if r.file }
      end
      out.each_value { |v| v.sort!.uniq! }
      out
    end

    def affected
      {
        "uncovered_changed_files" => @selection.uncovered_files.sort,
        "co_executed_neighbors" => co_executed_neighbors.sort,
        "escalations" => @selection.escalations.map do |e|
          { "file" => e.file, "reason" => e.cause }
        end
      }
    end

    # Source files that share examples with the changed source files.
    def co_executed_neighbors
      neighbors = Set.new
      changed = @outcome.changed_source_files || []
      Map.example_keys(@map).each do |example|
        files = (@map[example] || {}).keys
        next if (files & changed).empty?

        files.each { |f| neighbors << f unless changed.include?(f) }
      end
      neighbors.to_a
    end

    # Per-PR diff coverage: the *added* lines from the diff, minus every line
    # executed during this PR's runs, resolved to method names. Falls back to
    # the escalation-based approximation when no live coverage digest is present
    # (e.g. a full run, or tests driven by a fake runner).
    def untested_new_code
      if diff_coverage_available?
        diff_coverage
      else
        new_method_escalations
      end
    end

    def diff_coverage_available?
      @executed_lines && @changed_sources && !@changed_sources.empty?
    end

    def diff_coverage
      @changed_sources.each_with_object([]) do |cs, out|
        next unless cs.head_index

        added = Array(cs.hunks).flat_map(&:to_a).uniq
        ran = @executed_lines[cs.path] || []
        missed = added - ran
        next if missed.empty?

        resolver = Resolver.new(cs.head_index)
        missed.group_by { |line| resolver.method_for(line) }.each do |method, lines|
          out << { "file" => cs.path, "method" => method, "lines" => [lines.min, lines.max] }
        end
      end
    end

    def new_method_escalations
      @selection.escalations
                .select { |e| e.cause == "new_method" && e.method }
                .map { |e| { "file" => e.file, "method" => e.method } }
                .uniq
    end

    def nondeterminism
      (@outcome.changed_source_files || []).flat_map do |file|
        next [] unless File.exist?(file)

        RotLint.scan(File.read(file), file: file).map do |finding|
          {
            "file" => finding.file, "line" => finding.line,
            "pattern" => finding.pattern, "severity" => finding.severity,
            "exposed_examples" => RotLint.exposure(finding.file, @map)
          }
        end
      end
    rescue StandardError
      []
    end

    def selection_trace
      trace = {}
      @selection.example_reasons.each do |example, reasons|
        trace[example] = reasons.map { |r| reason_hash(r) }
      end
      @selection.file_reasons.each do |file, reasons|
        trace[file] = reasons.map { |r| reason_hash(r) }
      end
      trace
    end

    def reason_hash(reason)
      { "rule" => reason.rule, "file" => reason.file,
        "method" => reason.method, "cause" => reason.cause }.compact
    end

    def trace_lines
      selection_trace.map do |key, reasons|
        rules = reasons.map { |r| r["rule"] }.uniq.join(", ")
        "  #{key} <- #{rules}"
      end
    end
  end
end
