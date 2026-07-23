# frozen_string_literal: true

require "psych"

module Testalaria
  # The committed test map: `example_id => { source_file => [methods] }`, plus
  # `:commit` / `:timestamp` / `:version` metadata. This module is the pure
  # in-memory representation and its deterministic (de)serialization. File IO
  # lives in MapStore.
  #
  # The on-disk shape mirrors the design doc exactly — symbol metadata keys and
  # string example keys in one YAML mapping:
  #
  #   :commit: <sha>
  #   :timestamp: 1753142400
  #   :version: 1
  #   "./spec/x_spec.rb[1:1]":
  #     app/models/player.rb:
  #       - "Player#fn_one"
  #
  # Determinism is mandatory (the file lives in git): example keys sorted, file
  # keys sorted, method lists uniq+sorted, no per-entry timestamps. Same inputs
  # => byte-identical output.
  module Map
    VERSION = 1
    META_KEYS = %i[commit timestamp version].freeze

    module_function

    # An empty map with metadata scaffolding.
    def empty
      { version: VERSION }
    end

    # Parse a YAML string into a map hash. Returns {empty} for blank/absent.
    def load(yaml)
      return empty if yaml.nil? || yaml.strip.empty?

      data = Psych.respond_to?(:unsafe_load) ? Psych.unsafe_load(yaml) : Psych.load(yaml)
      data.is_a?(Hash) ? data : empty
    end

    # Serialize a map hash to deterministic YAML.
    def dump(map)
      ordered = {}
      META_KEYS.each { |k| ordered[k] = map[k] if map.key?(k) }
      ordered[:version] ||= VERSION

      example_keys(map).sort.each do |ex|
        files = map[ex] || {}
        ordered[ex] = files.keys.sort.each_with_object({}) do |file, acc|
          acc[file] = Array(files[file]).uniq.sort
        end
      end

      Psych.dump(ordered)
    end

    # Every example key (i.e. non-metadata top-level key).
    def example_keys(map)
      map.keys.reject { |k| META_KEYS.include?(k) }
    end

    # Overlay fresh example entries onto a base map, replacing any prior entry
    # for the same example id. Order-independent in result content.
    #
    # @param updates [Hash] example_id => { file => [methods] }
    def merge(base, updates)
      result = base.dup
      updates.each { |example_id, files| result[example_id] = files }
      result
    end

    # Remove every example key that begins with the given prefix (the test-file
    # staleness purge: e.g. "./spec/x_spec.rb" removes "./spec/x_spec.rb[...]").
    def prune_by_prefix(map, prefix)
      map.reject { |k| example_key?(k) && k.to_s.start_with?(prefix) }
    end

    # Remove specific example ids.
    def prune_examples(map, ids)
      set = ids.to_a
      map.reject { |k| example_key?(k) && set.include?(k) }
    end

    def example_key?(key)
      !META_KEYS.include?(key)
    end
  end
end
