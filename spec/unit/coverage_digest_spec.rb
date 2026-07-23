# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::CoverageDigest do
  describe ".merge" do
    it "unions executed lines per file, order-independent" do
      base = { "a.rb" => [1, 3], "b.rb" => [5] }
      updates = { "a.rb" => [3, 2], "c.rb" => [9] }
      merged = described_class.merge(base, updates)
      expect(merged["a.rb"]).to eq([1, 2, 3])
      expect(merged["b.rb"]).to eq([5])
      expect(merged["c.rb"]).to eq([9])
      expect(base["a.rb"]).to eq([1, 3]) # base untouched
    end
  end
end

RSpec.describe Testalaria::CoverageDigestStore do
  it "round-trips a digest through an atomic write" do
    Dir.mktmpdir do |dir|
      store = described_class.new(path: File.join(dir, ".testalaria.coverage.yml"))
      store.dump("app/a.rb" => [1, 2, 3])
      expect(store.load).to eq("app/a.rb" => [1, 2, 3])
      store.delete
      expect(store.load).to eq({})
    end
  end
end
