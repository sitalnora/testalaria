# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::ConstIndex do
  it "maps a constant read to its enclosing (file, method)" do
    index = described_class.build(
      "app/models/player.rb" => "class Player\n  def fn\n    PROMOTING_SCORE\n  end\nend\n"
    )
    expect(index.sites_for(["PROMOTING_SCORE"])).to eq([["app/models/player.rb", "Player#fn"]])
  end

  it "matches a namespaced read (Ns::X) by the bare name" do
    index = described_class.build(
      "app/x.rb" => "class X\n  def go\n    Player::PROMOTING_SCORE\n  end\nend\n"
    )
    expect(index.sites_for(["PROMOTING_SCORE"])).to eq([["app/x.rb", "X#go"]])
  end

  it "ignores the assignment/definition site — only reads count" do
    index = described_class.build(
      "app/player.rb" => "class Player\n  PROMOTING_SCORE = 36\nend\n"
    )
    expect(index.sites_for(["PROMOTING_SCORE"])).to eq([])
  end

  it "returns nothing for a constant no source reads" do
    index = described_class.build("app/x.rb" => "class X\n  def go\n    1\n  end\nend\n")
    expect(index.sites_for(["NOPE"])).to eq([])
  end

  it "records reads across multiple methods and files" do
    index = described_class.build(
      "app/a.rb" => "class A\n  def m\n    LIMIT\n  end\nend\n",
      "app/b.rb" => "class B\n  def n\n    LIMIT\n  end\nend\n"
    )
    expect(index.sites_for(["LIMIT"])).to contain_exactly(
      ["app/a.rb", "A#m"], ["app/b.rb", "B#n"]
    )
  end

  it "silently skips unparseable source" do
    expect { described_class.build("app/broken.rb" => "def (\n") }.not_to raise_error
  end
end
