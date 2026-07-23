# frozen_string_literal: true

require "coverage"

module Testalaria
  # The Coverage source seam. Ruby allows only one `Coverage.start`, and
  # SimpleCov owns it when present, so this wrapper never double-starts:
  #
  #   * if a session is already running -> piggyback (peek only)
  #   * otherwise -> start our own `lines: true` session
  #
  # Never `oneshot_lines`: it fires each line once ever, which makes per-example
  # diffing impossible. If a running session turns out to be oneshot, `peek`
  # detects it and raises loudly rather than silently mis-mapping.
  class CoverageSource
    def initialize(coverage = ::Coverage)
      @coverage = coverage
      @started_by_us = false
    end

    def running?
      @coverage.respond_to?(:running?) && @coverage.running?
    end

    # Start our own session only if nothing else did.
    def start
      return if running?

      @coverage.start(lines: true)
      @started_by_us = true
    end

    # @return [Hash{String=>Array}] { absolute_file => [per-line counts] },
    #   nils preserved for non-executable lines.
    # @raise [OneshotCoverageError] if the running session is oneshot mode
    def peek
      normalize(@coverage.peek_result)
    end

    private

    def normalize(result)
      result.each_with_object({}) do |(file, data), acc|
        acc[file] = lines_from(data, file)
      end
    end

    def lines_from(data, file)
      case data
      when Array
        data
      when Hash
        if data.key?(:oneshot_lines)
          raise OneshotCoverageError,
                "Coverage is running in oneshot_lines mode, which cannot be " \
                "diffed per example. Start coverage with `lines: true` " \
                "(or let SimpleCov 0.18+ manage it) and retry. (file: #{file})"
        end
        data[:lines] || []
      else
        []
      end
    end
  end
end
