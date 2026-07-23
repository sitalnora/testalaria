# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::RotLint do
  def patterns(src, **opts)
    described_class.scan(src, file: "app/x.rb", **opts).map(&:pattern)
  end

  it "flags clock reads" do
    expect(patterns("if Date.today.saturday?\n  1\nend\n")).to include("Date.today")
    expect(patterns("x = Time.now\n")).to include("Time.now")
    expect(patterns("x = Time.current\n")).to include("Time.current")
  end

  it "flags randomness" do
    expect(patterns("x = rand(10)\n")).to include("rand")
    expect(patterns("a.sample\n")).to include("sample")
    expect(patterns("a.shuffle\n")).to include("shuffle")
  end

  it "flags ENV reads" do
    expect(patterns("x = ENV['FOO']\n")).to include("ENV")
  end

  it "flags configured feature-flag readers" do
    expect(patterns("Flipper.enabled?(:x)\n")).to include("Flipper.enabled?")
  end

  it "does not flag an ordinary method call named like a receiver method" do
    expect(patterns("obj.current_user\n")).to be_empty
  end

  it "downgrades clock reads to info in a guarded test file" do
    src = "travel_to(Time.zone.local(2020)) do\n  Time.now\nend\n"
    finding = described_class.scan(src, file: "spec/x_spec.rb", test_file: true).find { |f| f.pattern == "Time.now" }
    expect(finding.severity).to eq("info")
  end

  describe ".exposure" do
    it "counts examples whose entry includes the offending file" do
      map = {
        version: 1,
        "e1" => { "app/x.rb" => ["X#m"] },
        "e2" => { "app/x.rb" => ["X#n"], "app/y.rb" => ["Y#m"] },
        "e3" => { "app/y.rb" => ["Y#m"] }
      }
      expect(described_class.exposure("app/x.rb", map)).to eq(2)
    end
  end
end
