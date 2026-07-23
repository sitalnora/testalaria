# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::StubIndex do
  it "indexes a stubbed method symbol to the test file" do
    index = described_class.build("spec/a_spec.rb" => "allow(x).to receive(:fn_one)\n")
    expect(index.test_files_for(["Player#fn_one"])).to eq(["spec/a_spec.rb"])
  end

  it "indexes expect(...).to receive(:sym)" do
    index = described_class.build(
      "spec/b_spec.rb" => "expect(order).to receive(:apply_discount)\n"
    )
    expect(index.test_files_for(["Order#apply_discount"])).to eq(["spec/b_spec.rb"])
  end

  it "indexes instance_double(Const) and class_double(Const) by class name" do
    index = described_class.build(
      "spec/c_spec.rb" => "let(:p) { instance_double(Player) }\n",
      "spec/d_spec.rb" => "class_double(Player).as_stubbed_const\n"
    )
    expect(index.test_files_for(["Player#anything"])).to contain_exactly("spec/c_spec.rb", "spec/d_spec.rb")
  end

  it "returns nothing for methods no test stubs" do
    index = described_class.build("spec/a_spec.rb" => "allow(x).to receive(:other)\n")
    expect(index.test_files_for(["Player#fn_one"])).to eq([])
  end

  it "ignores the toplevel bucket" do
    index = described_class.build("spec/a_spec.rb" => "receive(:x)\n")
    expect(index.test_files_for([Testalaria::DefIndex::TOPLEVEL])).to eq([])
  end
end
