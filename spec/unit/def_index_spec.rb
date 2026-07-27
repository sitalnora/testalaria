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

  it "qualifies methods by a compact-nested class path (Foo::Bar)" do
    src = <<~RUBY
      class Outer::Inner
        def m; end
      end
    RUBY
    expect(table(src)).to eq([["Outer::Inner#m", 2..2]])
  end

  it "resolves a top-level-anchored constant (::Foo)" do
    src = <<~RUBY
      class ::Foo
        def m; end
      end
    RUBY
    expect(table(src)).to eq([["Foo#m", 2..2]])
  end

  it "indexes a class-level `def self.x` singleton" do
    src = <<~RUBY
      class Player
        def self.build; end
      end
    RUBY
    expect(table(src)).to eq([["Player.build", 2..2]])
  end

  it "records multiple singleton methods in one `class << self` block" do
    src = <<~RUBY
      class Player
        class << self
          def a; end
          def b; end
        end
      end
    RUBY
    expect(table(src)).to eq([["Player.a", 3..3], ["Player.b", 4..4]])
  end

  it "flags a def nested inside a def as dynamic and indexes only the outer" do
    src = <<~RUBY
      class Player
        def outer
          def inner; end
        end
      end
    RUBY
    di = described_class.build(src)
    expect(di.entries.map(&:name)).to eq(["Player#outer"])
    expect(di.dynamic?).to be(true)
  end

  it "flags module_eval and instance_eval as dynamic" do
    expect(described_class.build("class P\n  module_eval { 1 }\nend\n").dynamic?).to be(true)
    expect(described_class.build("class P\n  instance_eval { 1 }\nend\n").dynamic?).to be(true)
  end

  it "builds an empty, non-dynamic index from empty source (the collector fallback)" do
    di = described_class.build("")
    expect(di.entries).to eq([])
    expect(di.dynamic?).to be(false)
    expect(Testalaria::Resolver.new(di).method_for(1)).to eq(described_class::TOPLEVEL)
  end

  it "flags class_exec and instance_exec as dynamic" do
    expect(described_class.build("class P\n  class_exec { 1 }\nend\n").dynamic?).to be(true)
    expect(described_class.build("class P\n  instance_exec { 1 }\nend\n").dynamic?).to be(true)
  end

  it "still indexes static defs in a file that is also dynamic (mixed)" do
    src = <<~RUBY
      class Player
        def real
          1
        end
        define_method(:dyn) { 2 }
      end
    RUBY
    di = described_class.build(src)
    expect(di.entries.map(&:name)).to eq(["Player#real"])
    expect(di.dynamic?).to be(true)
  end

  describe "constant assignments (const_entries)" do
    def const_names(src)
      described_class.build(src).const_entries.map(&:name)
    end

    it "records a top-level constant assignment with its line range" do
      src = <<~RUBY
        module Player
          PROMOTING_SCORE = 36
          def fn; end
        end
      RUBY
      di = described_class.build(src)
      expect(di.const_entries.map(&:name)).to eq(["PROMOTING_SCORE"])
      expect(di.const_entries.first.range).to eq(2..2)
    end

    it "records a namespaced constant assignment by its bare name" do
      expect(const_names("Foo::BAR = 1\n")).to eq(["BAR"])
    end

    it "records an ||= constant assignment" do
      expect(const_names("class C\n  X ||= 1\nend\n")).to eq(["X"])
    end

    it "records assignments, not reads, and not the class name" do
      src = <<~RUBY
        class C
          LIMIT = 10
          def fn
            LIMIT + 1
          end
        end
      RUBY
      expect(const_names(src)).to eq(["LIMIT"])
    end
  end
end
