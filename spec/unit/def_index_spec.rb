# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::DefIndex do
  # Convenience: [[name, range], ...]
  def table(src)
    described_class.build(src).entries.map { |e| [e.name, e.range] }
  end

  it "indexes a simple instance method by enclosing class" do
    src = <<~RUBY
      class Cece
        def fn
          1
        end
      end
    RUBY
    expect(table(src)).to eq([["Cece#fn", 2..3]])
  end

  it "handles nested modules and singleton (def self.x) methods" do
    src = <<~RUBY
      module A
        module B
          def m; end
          def self.sm; end
        end
      end
    RUBY
    expect(table(src)).to eq([["A::B#m", 3..3], ["A::B.sm", 4..4]])
  end

  it "indexes singleton methods defined in a `class << self` block" do
    src = <<~RUBY
      class Player
        class << self
          def helper; end
        end
      end
    RUBY
    expect(table(src)).to eq([["Player.helper", 3..3]])
  end

  it "records multiple methods in one class in start-line order" do
    src = <<~RUBY
      class Player
        def fn_one
          1
        end

        def fn_two
          2
        end
      end
    RUBY
    expect(table(src)).to eq([["Player#fn_one", 2..3], ["Player#fn_two", 6..7]])
  end

  it "puts class-body (macro) code outside any def -> resolves to toplevel" do
    src = <<~RUBY
      class Player
        validates :name, presence: true

        def fn
          2
        end
      end
    RUBY
    di = described_class.build(src)
    expect(di.entries.map(&:name)).to eq(["Player#fn"])
    expect(di.entries.first.range).to eq(4..5)
    # line 2 (validates) is covered by no def
    expect(Testalaria::Resolver.new(di).method_for(2)).to eq(Testalaria::DefIndex::TOPLEVEL)
  end

  it "flags define_method as dynamic and does not index it" do
    src = <<~RUBY
      class Player
        define_method(:x) { 1 }
      end
    RUBY
    di = described_class.build(src)
    expect(di.entries).to be_empty
    expect(di.dynamic?).to be(true)
  end

  it "flags string class_eval as dynamic" do
    src = <<~RUBY
      class Player
        class_eval "def y; end"
      end
    RUBY
    expect(described_class.build(src).dynamic?).to be(true)
  end

  it "raises a typed ParseError on a syntax error" do
    expect { described_class.build("def (") }.to raise_error(Testalaria::ParseError)
  end

  it "does not corrupt end-line detection with heredocs in a body" do
    src = <<~RUBY
      class Player
        def banner
          <<~TEXT
            hello
          TEXT
        end
        def after
          9
        end
      end
    RUBY
    names = table(src)
    # banner and after must not overlap; after starts after banner ends
    banner = names.find { |n, _| n == "Player#banner" }
    after = names.find { |n, _| n == "Player#after" }
    expect(banner[1].begin).to eq(2)
    expect(after[1].begin).to eq(7)
    expect(banner[1].end).to be < after[1].begin
  end

  context "on Ruby >= 3.0 (endless method defs)" do
    it "indexes a one-line def" do
      skip "endless defs need Ruby 3.0+" if RUBY_VERSION < "3.0"
      src = <<~RUBY
        class Player
          def x = 1
        end
      RUBY
      expect(table(src)).to eq([["Player#x", 2..2]])
    end
  end
end
