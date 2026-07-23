# frozen_string_literal: true

require "spec_helper"

RSpec.describe Player do
  describe "#fn_one" do
    it "greets with the name" do
      expect(Player.new("a").fn_one).to eq("one:a")
    end

    context "when composed through fn_two" do
      it "upcases the greeting" do
        expect(Player.new("a").fn_two).to eq("ONE:A")
      end
    end
  end

  it "defines a dynamic greeter" do
    expect(Player.new("a").dynamic_greet).to eq("hi a")
  end
end
