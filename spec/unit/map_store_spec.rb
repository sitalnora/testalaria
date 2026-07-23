# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::MapStore do
  it "returns an empty scaffold when the file does not exist" do
    Dir.mktmpdir do |dir|
      store = described_class.new(path: File.join(dir, "nope.yml"))
      expect(store.load).to eq(Testalaria::Map.empty)
    end
  end

  it "round-trips a map and leaves no stray tmp file behind" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".testalaria.yml")
      store = described_class.new(path: path)
      store.dump(version: 1, "e[1:1]" => { "a.rb" => ["A#m"] })

      # The atomic write renames the tmp file into place — nothing else remains.
      expect(Dir.children(dir)).to eq([".testalaria.yml"])
      expect(store.load["e[1:1]"]).to eq("a.rb" => ["A#m"])
    end
  end

  it "creates missing parent directories on dump" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "deep", "map.yml")
      described_class.new(path: path).dump(version: 1)
      expect(File.exist?(path)).to be(true)
    end
  end

  it "writes deterministic YAML (same content regardless of insertion order)" do
    Dir.mktmpdir do |dir|
      a = described_class.new(path: File.join(dir, "a.yml"))
      b = described_class.new(path: File.join(dir, "b.yml"))
      a.dump(version: 1, "y[1:1]" => { "b.rb" => ["B#n"] }, "x[1:1]" => { "a.rb" => ["A#m"] })
      b.dump("x[1:1]" => { "a.rb" => ["A#m"] }, "y[1:1]" => { "b.rb" => ["B#n"] }, version: 1)
      expect(File.read(File.join(dir, "a.yml"))).to eq(File.read(File.join(dir, "b.yml")))
    end
  end
end
