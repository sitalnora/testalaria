# frozen_string_literal: true

require "ripper"
require "testalaria/map"

module Testalaria
  # Static scan for nondeterminism patterns — code whose behaviour depends on
  # inputs outside the repo, i.e. exactly the rot vectors the diff-driven
  # machinery cannot see. Proves *presence*, never absence (gems and
  # metaprogrammed access escape it), which is why it pairs with the dynamic
  # signal (map churn on unchanged test files). Pure: source in, findings out;
  # findings are joined against the map by the caller/report.
  class RotLint
    CLOCK_RECEIVERS = %w[Date Time].freeze
    CLOCK_METHODS = %w[now today current].freeze
    RANDOM_METHODS = %w[rand sample shuffle].freeze
    DEFAULT_FLAG_RECEIVERS = %w[Flipper].freeze
    TIME_GUARDS = %w[travel_to freeze_time Timecop].freeze

    Finding = Struct.new(:file, :line, :pattern, :severity, keyword_init: true)

    def self.scan(source, file:, test_file: false, flag_receivers: DEFAULT_FLAG_RECEIVERS)
      sexp = Ripper.sexp(source)
      return [] unless sexp

      new(file, test_file, source, flag_receivers).run(sexp)
    end

    # How many map examples hold an edge through the offending file.
    def self.exposure(file, map)
      Map.example_keys(map).count { |ex| (map[ex] || {}).key?(file) }
    end

    def initialize(file, test_file, source, flag_receivers)
      @file = file
      @test_file = test_file
      @guarded = test_file && TIME_GUARDS.any? { |g| source.include?(g) }
      @flag_receivers = flag_receivers
      @findings = []
    end

    def run(sexp)
      walk(sexp)
      @findings.uniq { |f| [f.line, f.pattern] }.sort_by(&:line)
    end

    private

    def walk(node)
      return unless node.is_a?(Array)

      detect_call(node)
      detect_env(node)
      detect_random(node)
      node.each { |child| walk(child) }
    end

    def detect_call(node)
      return unless %i[call command_call].include?(node[0])

      recv = const_name(node[1])
      ident = node[0] == :call ? node[3] : node[3]
      return unless ident.is_a?(Array) && ident[0] == :@ident

      meth = ident[1]
      line = ident[2][0]
      if CLOCK_RECEIVERS.include?(recv) && CLOCK_METHODS.include?(meth)
        add("#{recv}.#{meth}", line, clock_severity)
      elsif @flag_receivers.include?(recv) && meth.end_with?("enabled?")
        add("#{recv}.#{meth}", line, "warn")
      end
    end

    def detect_env(node)
      return unless node[0] == :@const && node[1] == "ENV"

      add("ENV", node[2][0], "warn")
    end

    def detect_random(node)
      return unless node[0] == :@ident && RANDOM_METHODS.include?(node[1])

      add(node[1], node[2][0], "warn")
    end

    def const_name(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :var_ref, :vcall then const_name(node[1])
      when :@const then node[1]
      end
    end

    def clock_severity
      @guarded ? "info" : "warn"
    end

    def add(pattern, line, severity)
      @findings << Finding.new(file: @file, line: line, pattern: pattern, severity: severity)
    end
  end
end
