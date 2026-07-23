# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::CoverageSource do
  describe "#start" do
    it "starts its own lines: session only when nothing is running" do
      backend = double("Coverage", running?: false)
      expect(backend).to receive(:start).with(lines: true)
      described_class.new(backend).start
    end

    it "piggybacks (never double-starts) on an already-running session" do
      backend = double("Coverage", running?: true)
      expect(backend).not_to receive(:start)
      described_class.new(backend).start
    end
  end

  describe "#running?" do
    it "is false when the backend does not expose running?" do
      expect(described_class.new(Object.new).running?).to be(false)
    end

    it "delegates to the backend when available" do
      expect(described_class.new(double(running?: true)).running?).to be(true)
    end
  end

  describe "#peek" do
    it "passes array-shaped per-line counts through unchanged" do
      src = described_class.new(double(peek_result: { "a.rb" => [1, nil, 0] }))
      expect(src.peek).to eq("a.rb" => [1, nil, 0])
    end

    it "extracts :lines from hash-shaped (branches:) results" do
      src = described_class.new(double(peek_result: { "a.rb" => { lines: [1, 2], branches: {} } }))
      expect(src.peek).to eq("a.rb" => [1, 2])
    end

    it "yields [] for an unexpected value shape rather than crashing" do
      src = described_class.new(double(peek_result: { "a.rb" => nil }))
      expect(src.peek).to eq("a.rb" => [])
    end

    it "raises loudly on oneshot_lines, which cannot be diffed per example" do
      src = described_class.new(double(peek_result: { "a.rb" => { oneshot_lines: [1] } }))
      expect { src.peek }.to raise_error(Testalaria::OneshotCoverageError)
    end
  end
end
