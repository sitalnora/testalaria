# frozen_string_literal: true

require "spec_helper"

# The two auto-install entry points must be safe to load when TESTALARIA is not
# set — that's what lets a project require them unconditionally without
# affecting ordinary test runs.
RSpec.describe "adapter activation entry points" do
  it "is inactive in this suite (guards the no-op assertions below)" do
    expect(Testalaria::Session.active?).to be(false)
  end

  it "requiring testalaria/rspec is a harmless no-op when inactive" do
    expect { require "testalaria/rspec" }.not_to raise_error
    # install! returns without touching RSpec config when not active
    expect(Testalaria::Adapters::RSpec.install!).to be_nil
  end

  it "the Minitest plugin init is a no-op when inactive" do
    require "minitest/testalaria_plugin"
    expect(Minitest.plugin_testalaria_init({})).to be_nil
  end
end
