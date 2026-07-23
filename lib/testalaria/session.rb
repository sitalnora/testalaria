# frozen_string_literal: true

require "testalaria/collector"
require "testalaria/coverage_source"
require "testalaria/coverage_digest"
require "testalaria/map"
require "testalaria/map_store"

module Testalaria
  # The per-process recording session, active only under TESTALARIA=1. Owns the
  # collector, accumulates one entry per example, and flushes a merged map at
  # suite end. Adapters (RSpec/Minitest) drive it through the same three calls.
  #
  # For reproducible maps (the byte-identical-twice guarantee and goldens), the
  # otherwise-live `:commit` and `:timestamp` can be pinned via env:
  #   TESTALARIA_COMMIT, TESTALARIA_TIMESTAMP, TESTALARIA_MAP (map path).
  class Session
    ENV_FLAG = "TESTALARIA"

    class << self
      def active?
        ENV[ENV_FLAG] == "1"
      end

      def current
        @current ||= new
      end

      # Test hook: drop the memoized session.
      def reset!
        @current = nil
      end
    end

    attr_reader :entries

    def initialize(coverage: CoverageSource.new,
                   store: MapStore.new(path: ENV.fetch("TESTALARIA_MAP", MapStore::DEFAULT_PATH)),
                   root: Dir.pwd,
                   clock: Time)
      @collector = Collector.new(coverage: coverage, root: root)
      @coverage = coverage
      @store = store
      @clock = clock
      @entries = {}
      @coverage.start
    end

    def start_example(_id)
      @collector.start_example
    end

    def finish_example(id)
      @entries[id] = @collector.finish_example
    end

    # Merge accumulated entries into the stored map and write it out, and merge
    # this run's executed lines into the coverage digest (for diff coverage).
    def flush
      base = @store.load
      # Test-file staleness: an example we just re-ran replaces its prior entry;
      # Map.merge already does that key-by-key.
      merged = Map.merge(base, @entries)
      merged[:commit] = commit
      merged[:timestamp] = timestamp
      merged[:version] = Map::VERSION
      @store.dump(merged)
      flush_coverage_digest
    end

    private

    def flush_coverage_digest
      store = CoverageDigestStore.new
      store.dump(CoverageDigest.merge(store.load, @collector.executed_lines))
    end

    def commit
      ENV["TESTALARIA_COMMIT"] || nil
    end

    def timestamp
      env = ENV["TESTALARIA_TIMESTAMP"]
      env ? env.to_i : @clock.now.to_i
    end
  end
end
