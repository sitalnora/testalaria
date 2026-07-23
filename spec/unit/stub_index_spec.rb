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

  it "indexes have_received(:sym)" do
    index = described_class.build("spec/a_spec.rb" => "expect(x).to have_received(:save)\n")
    expect(index.test_files_for(["Order#save"])).to eq(["spec/a_spec.rb"])
  end

  it "indexes the first symbol of a receive_message_chain" do
    index = described_class.build("spec/a_spec.rb" => "allow(x).to receive_message_chain(:a, :b)\n")
    expect(index.test_files_for(["X#a"])).to eq(["spec/a_spec.rb"])
  end

  it "indexes allow_any_instance_of(Const) by class name" do
    index = described_class.build(
      "spec/a_spec.rb" => "allow_any_instance_of(Player).to receive(:fn)\n"
    )
    expect(index.test_files_for(["Player#anything"])).to include("spec/a_spec.rb")
  end

  it "indexes object_double(Const) by class name" do
    index = described_class.build("spec/a_spec.rb" => "object_double(Player)\n")
    expect(index.test_files_for(["Player#x"])).to eq(["spec/a_spec.rb"])
  end

  it "sees a stub written in block form (method_add_block)" do
    index = described_class.build("spec/a_spec.rb" => "allow(x).to receive(:fn_one) { 42 }\n")
    expect(index.test_files_for(["Player#fn_one"])).to eq(["spec/a_spec.rb"])
  end

  it "silently skips a test file that cannot be parsed" do
    index = nil
    expect { index = described_class.build("spec/a_spec.rb" => "def (\n") }.not_to raise_error
    expect(index.symbols).to be_empty
  end

  it "does not index a stub whose method is a variable, not a symbol literal" do
    # Dynamic stub target -> conservative miss (can't know the name statically).
    index = described_class.build("spec/a_spec.rb" => "allow(x).to receive(method_name)\n")
    expect(index.symbols).to be_empty
    expect(index.test_files_for(["Player#method_name"])).to eq([])
  end
end
