# frozen_string_literal: true

require "fileutils"
require "psych"

module Testalaria
  # A gitignored sidecar carrying the union of source lines executed during a
  # PR's test runs — the one thing the map can't provide (it stores method
  # names, not lines). Each subprocess run merges its executed set in; the
  # orchestration reads the accumulated digest back to compute diff-coverage
  # ("added lines minus executed lines") for the report.
  #
  # Shape on disk: a flat `{ "path.rb" => [sorted executed line numbers] }`.
  # Determinism doesn't matter here (ephemeral, never committed), but sorting
  # keeps it diff-friendly for debugging.
  module CoverageDigest
    module_function

    # Union of executed lines per file, order-independent.
    def merge(base, updates)
      result = base.each_with_object({}) { |(f, lines), acc| acc[f] = lines.dup }
      updates.each do |file, lines|
        result[file] = ((result[file] || []) | lines).sort
      end
      result
    end
  end

  # File IO for the coverage digest, atomic like MapStore.
  class CoverageDigestStore
    DEFAULT_PATH = ".testalaria.coverage.yml"

    def self.path
      ENV["TESTALARIA_COVERAGE"] || DEFAULT_PATH
    end

    attr_reader :path

    def initialize(path: self.class.path)
      @path = path
    end

    def load
      return {} unless File.exist?(@path)

      data = Psych.respond_to?(:unsafe_load) ? Psych.unsafe_load(File.read(@path)) : Psych.load(File.read(@path))
      data.is_a?(Hash) ? data : {}
    end

    def dump(digest)
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.write(tmp, Psych.dump(digest))
      File.rename(tmp, @path)
      digest
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def delete
      File.delete(@path) if File.exist?(@path)
    end
  end
end
