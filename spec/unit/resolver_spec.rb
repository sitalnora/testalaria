# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Resolver do
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

  subject(:resolver) { described_class.new(Testalaria::DefIndex.build(source)) }

  it "maps a line inside a def to its method name" do
    expect(resolver.method_for(3)).to eq("Player#fn_one")
    expect(resolver.method_for(7)).to eq("Player#fn_two")
  end

  it "maps a line outside every def to toplevel" do
    expect(resolver.method_for(1)).to eq(Testalaria::DefIndex::TOPLEVEL)
  end

  it "returns unique, sorted names for a set of lines" do
    expect(resolver.names_for([7, 3, 3])).to eq(["Player#fn_one", "Player#fn_two"])
  end

  it "includes toplevel when any line falls outside a def" do
    expect(resolver.names_for([1, 3])).to eq([Testalaria::DefIndex::TOPLEVEL, "Player#fn_one"])
  end
end
