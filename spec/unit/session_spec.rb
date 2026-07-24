# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::Session do
  # Session reads several env flags and memoizes a process-global instance.
  # Save/restore the env and drop the memo around every example so nothing
  # leaks between tests (or into the rest of the suite).
  around do |example|
    keys = %w[TESTALARIA TESTALARIA_COMMIT TESTALARIA_TIMESTAMP TESTALARIA_COVERAGE]
    saved = keys.map { |k| [k, ENV[k]] }
    described_class.reset!
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    described_class.reset!
  end

  def build_session(store: FakeMapStore.new, snapshots: [{}, {}], clock: FixedClock.new)
    described_class.new(coverage: FakeCoverage.new(snapshots: snapshots), store: store, clock: clock)
  end

  describe ".active?" do
    it "is true only when TESTALARIA == '1'" do
      ENV["TESTALARIA"] = "1"
      expect(described_class.active?).to be(true)
      ENV["TESTALARIA"] = "0"
      expect(described_class.active?).to be(false)
      ENV.delete("TESTALARIA")
      expect(described_class.active?).to be(false)
    end
  end

  describe ".current / .reset!" do
    it "memoizes a single session and rebuilds after reset!" do
      # Stub the coverage seam so .current does not boot a real Coverage run.
      allow(Testalaria::CoverageSource).to receive(:new).and_return(FakeCoverage.new)
      first = described_class.current
      expect(described_class.current).to equal(first)
      described_class.reset!
      expect(described_class.current).not_to equal(first)
    end
  end

  describe "#start_example / #finish_example" do
    it "accumulates one entry per finished example, keyed by id" do
      session = build_session(snapshots: [{}, {}, {}, {}])
      session.start_example("e1")
      session.finish_example("e1")
      session.start_example("e2")
      session.finish_example("e2")
      expect(session.entries.keys).to eq(%w[e1 e2])
    end
  end

  describe "#flush" do
    it "merges entries into the store with commit/timestamp/version metadata" do
      Dir.mktmpdir do |dir|
        ENV["TESTALARIA_COVERAGE"] = File.join(dir, "cov.yml")
        ENV["TESTALARIA_COMMIT"] = "deadbeef"
        ENV.delete("TESTALARIA_TIMESTAMP")
        store = FakeMapStore.new
        session = build_session(store: store)
        session.start_example("e1")
        session.finish_example("e1")
        session.flush

        dumped = store.dumps.last
        expect(dumped["e1"]).to eq({})
        expect(dumped[:commit]).to eq("deadbeef")
        expect(dumped[:timestamp]).to eq(FixedClock::DEFAULT.to_i)
        expect(dumped[:version]).to eq(Testalaria::Map::VERSION)
      end
    end

    it "prefers an explicit TESTALARIA_TIMESTAMP over the clock" do
      Dir.mktmpdir do |dir|
        ENV["TESTALARIA_COVERAGE"] = File.join(dir, "cov.yml")
        ENV["TESTALARIA_TIMESTAMP"] = "1234"
        store = FakeMapStore.new
        build_session(store: store).flush
        expect(store.dumps.last[:timestamp]).to eq(1234)
      end
    end

    it "leaves :commit nil when TESTALARIA_COMMIT is unset" do
      Dir.mktmpdir do |dir|
        ENV["TESTALARIA_COVERAGE"] = File.join(dir, "cov.yml")
        ENV.delete("TESTALARIA_COMMIT")
        store = FakeMapStore.new
        build_session(store: store).flush
        expect(store.dumps.last[:commit]).to be_nil
      end
    end

    # Regression: SimpleCov (or, on Ruby < 3.1, an undetectable state) can stop
    # Coverage before suite end, so peek raises "coverage measurement is not
    # enabled". The map is written before the digest, so flush must still succeed.
    it "still writes the map when Coverage is disabled at digest time" do
      Dir.mktmpdir do |dir|
        ENV["TESTALARIA_COVERAGE"] = File.join(dir, "cov.yml")
        cov = FakeCoverage.new
        def cov.peek
          raise "coverage measurement is not enabled"
        end
        store = FakeMapStore.new
        session = described_class.new(coverage: cov, store: store, clock: FixedClock.new)

        expect { session.flush }.not_to raise_error
        expect(store.dumps.last[:version]).to eq(Testalaria::Map::VERSION)
      end
    end
  end
end
