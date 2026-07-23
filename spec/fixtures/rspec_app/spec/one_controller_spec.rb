# frozen_string_literal: true

require "spec_helper"

RSpec.describe OneController do
  it "authenticates via the concern and returns the player greeting" do
    expect(OneController.new.index).to eq("one:aron")
  end

  it "registers the concern's before_action" do
    expect(OneController.before_actions).to include(:authenticate)
  end
end
