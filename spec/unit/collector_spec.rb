# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::Collector do
  # Writes a source file into a tmp root and returns [root, relative_path, abs].
  def with_source(body)
    Dir.mktmpdir do |root|
      abs = File.join(root, "player.rb")
      File.write(abs, body)
      yield(root, "player.rb", abs)
    end
  end

  let(:source) do
    <<~RUBY
      class Player
        def fn_one
          1
        end
        def fn_two
          2
        end
      end
    RUBY
  end

  it "attributes a moved line to its enclosing method" do
    with_source(source) do |root, rel, abs|
      before = { abs => [nil, nil, 0, nil, nil, 0, nil, nil] }
      after  = { abs => [nil, nil, 1, nil, nil, 0, nil, nil] } # line 3 moved
      cov = FakeCoverage.new(snapshots: [before, after])
      collector = described_class.new(coverage: cov, root: root)

      collector.start_example
      expect(collector.finish_example).to eq(rel => ["Player#fn_one"])
    end
  end

  it "cancels counters across examples (A's residue is not attributed to B)" do
    with_source(source) do |root, rel, abs|
      # snapshot sequence: start A, finish A, start B, finish B
      snaps = [
        { abs => [nil, nil, 0, nil, nil, 0, nil, nil] }, # A start
        { abs => [nil, nil, 1, nil, nil, 0, nil, nil] }, # A finish (line 3)
        { abs => [nil, nil, 1, nil, nil, 0, nil, nil] }, # B start (line 3 already run)
        { abs => [nil, nil, 1, nil, nil, 1, nil, nil] }  # B finish (line 6)
      ]
      cov = FakeCoverage.new(snapshots: snaps)
      collector = described_class.new(coverage: cov, root: root)

      collector.start_example
      expect(collector.finish_example).to eq(rel => ["Player#fn_one"])
      collector.start_example
      expect(collector.finish_example).to eq(rel => ["Player#fn_two"])
    end
  end

  it "ignores files outside the project root" do
    with_source(source) do |root, rel, abs|
      before = { abs => [nil, nil, 0, nil, nil, 0, nil, nil],
                 "/usr/lib/ruby/other.rb" => [0] }
      after  = { abs => [nil, nil, 1, nil, nil, 0, nil, nil],
                 "/usr/lib/ruby/other.rb" => [1] }
      cov = FakeCoverage.new(snapshots: [before, after])
      collector = described_class.new(coverage: cov, root: root)

      collector.start_example
      result = collector.finish_example
      expect(result.keys).to eq([rel])
    end
  end

  it "records nothing for an example that touches no project code" do
    with_source(source) do |root, _rel, abs|
      snap = { abs => [nil, nil, 0, nil, nil, 0, nil, nil] }
      cov = FakeCoverage.new(snapshots: [snap, snap])
      collector = described_class.new(coverage: cov, root: root)

      collector.start_example
      expect(collector.finish_example).to eq({})
    end
  end

  it "reports the cumulative executed source lines (for diff coverage)" do
    with_source(source) do |root, rel, abs|
      # cumulative counts: lines 2,3 (fn_one) and 5 (fn_two def) ran; 6 did not
      snap = { abs => [nil, 1, 1, nil, 1, 0, nil, nil] }
      cov = FakeCoverage.new(snapshots: [snap])
      collector = described_class.new(coverage: cov, root: root)
      expect(collector.executed_lines).to eq(rel => [2, 3, 5])
    end
  end

  it "normalizes hash-shaped (branches:) peek results and raises on oneshot" do
    # CoverageSource-level: hash with :lines is fine, :oneshot_lines raises.
    fine = { "a.rb" => { lines: [1], branches: {} } }
    oneshot = { "a.rb" => { oneshot_lines: [1] } }
    src = Testalaria::CoverageSource.new(double(peek_result: fine))
    expect(src.peek).to eq("a.rb" => [1])
    src2 = Testalaria::CoverageSource.new(double(peek_result: oneshot))
    expect { src2.peek }.to raise_error(Testalaria::OneshotCoverageError)
  end
end
