# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Map do
  describe ".dump determinism" do
    it "sorts example keys, file keys, and method lists" do
      map = {
        commit: "abc", timestamp: 1753142400, version: 1,
        "./spec/z_spec.rb[1:1]" => { "b.rb" => %w[B#y B#x], "a.rb" => ["A#m"] },
        "./spec/a_spec.rb[1:1]" => { "a.rb" => ["A#m"] }
      }
      yaml = described_class.dump(map)

      # Peek at the on-disk shape (run with `--format doc` to see it inline).
      puts "\n----- map YAML -----\n#{yaml}--------------------"

      # a_spec sorts before z_spec; within z_spec, a.rb before b.rb; methods sorted
      expect(yaml.index("a_spec")).to be < yaml.index("z_spec")
      expect(yaml.index("a.rb")).to be < yaml.index("b.rb")
      expect(yaml.index("B#x")).to be < yaml.index("B#y")
    end

    it "is byte-identical regardless of key insertion order" do
      a = { version: 1,
            "x[1:1]" => { "a.rb" => ["A#m"] },
            "y[1:1]" => { "b.rb" => ["B#n"] } }
      b = { "y[1:1]" => { "b.rb" => ["B#n"] },
            "x[1:1]" => { "a.rb" => ["A#m"] },
            version: 1 }
      expect(described_class.dump(a)).to eq(described_class.dump(b))
    end

    it "round-trips load(dump(x))" do
      map = { commit: "abc", timestamp: 42, version: 1,
              "e[1:1]" => { "a.rb" => ["A#m"] } }
      expect(described_class.load(described_class.dump(map))).to eq(map)
    end
  end

  describe ".merge" do
    it "replaces the entry for a re-run example and adds new ones" do
      base = { version: 1, "e1" => { "a.rb" => ["A#old"] } }
      updates = { "e1" => { "a.rb" => ["A#new"] }, "e2" => { "b.rb" => ["B#m"] } }
      merged = described_class.merge(base, updates)
      expect(merged["e1"]).to eq("a.rb" => ["A#new"])
      expect(merged["e2"]).to eq("b.rb" => ["B#m"])
      expect(base["e1"]).to eq("a.rb" => ["A#old"]) # base untouched
    end
  end

  describe ".prune_by_prefix" do
    it "removes exactly the keys for one test file, keeping metadata" do
      map = { version: 1,
              "./spec/x_spec.rb[1:1]" => { "a.rb" => ["A#m"] },
              "./spec/x_spec.rb[1:2]" => { "a.rb" => ["A#n"] },
              "./spec/y_spec.rb[1:1]" => { "b.rb" => ["B#m"] } }
      pruned = described_class.prune_by_prefix(map, "./spec/x_spec.rb")
      expect(pruned.keys).to contain_exactly(:version, "./spec/y_spec.rb[1:1]")
    end
  end

  describe ".prune_examples" do
    it "removes the named example ids, keeping the rest and the metadata" do
      map = { version: 1,
              "e1" => { "a.rb" => ["A#m"] },
              "e2" => { "b.rb" => ["B#n"] } }
      pruned = described_class.prune_examples(map, ["e1"])
      expect(pruned.keys).to contain_exactly(:version, "e2")
    end
  end

  describe ".load edge cases" do
    it "returns an empty scaffold for nil, blank, or whitespace-only input" do
      [nil, "", "   \n"].each do |blank|
        expect(described_class.load(blank)).to eq(described_class.empty)
      end
    end

    it "returns an empty scaffold when the YAML is not a mapping" do
      expect(described_class.load("- 1\n- 2\n")).to eq(described_class.empty)
    end
  end

  describe ".empty" do
    it "is version-stamped and holds no example keys" do
      expect(described_class.empty).to eq(version: Testalaria::Map::VERSION)
      expect(described_class.example_keys(described_class.empty)).to eq([])
    end
  end
end
