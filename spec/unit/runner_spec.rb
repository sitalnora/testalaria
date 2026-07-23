# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Runner do
  let(:process) { FakeRunner.new(scripted: { exit_status: 0, stdout: "" }) }
  subject(:runner) { described_class.new(process: process) }

  let(:rspec) { Testalaria::Config::Runner.new(name: "rspec", command: "bundle exec rspec", pattern: "spec/**/*_spec.rb") }
  let(:minitest) { Testalaria::Config::Runner.new(name: "minitest", command: "bundle exec rails test", pattern: "test/**/*_test.rb") }

  it "runs whole files with TESTALARIA=1 in the env" do
    runner.run_files(rspec, ["spec/a_spec.rb", "spec/b_spec.rb"])
    call = process.calls.first
    expect(call[:cmd]).to eq("bundle exec rspec spec/a_spec.rb spec/b_spec.rb")
    expect(call[:env]).to include("TESTALARIA" => "1")
  end

  it "passes RSpec example ids through as targets" do
    runner.run_examples(rspec, ["./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[1:2]"])
    expect(process.calls.first[:cmd]).to eq(
      "bundle exec rspec ./spec/a_spec.rb[1:1] ./spec/a_spec.rb[1:2]"
    )
  end

  it "groups Minitest example ids by file with an -n filter" do
    locator = Testalaria::TestLocator.new(
      "PlayerTest" => "test/player_test.rb"
    )
    runner.run_examples(minitest, %w[PlayerTest#test_a PlayerTest#test_b], locator: locator)
    expect(process.calls.first[:cmd]).to eq(
      'bundle exec rails test test/player_test.rb -n /test_a|test_b/'
    )
  end
end
