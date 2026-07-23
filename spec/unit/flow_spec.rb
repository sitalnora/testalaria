# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Flow do
  let(:config) do
    Testalaria::Config.new(
      "runners" => {
        "rspec" => { "command" => "rspec", "pattern" => "spec/**/*_spec.rb" },
        "minitest" => { "command" => "rails test", "pattern" => "test/**/*_test.rb" }
      }
    )
  end

  subject(:flow) do
    described_class.new(config: config, git: FakeGit.new, runner: Testalaria::Runner.new(process: FakeRunner.new),
                        store: FakeMapStore.new)
  end

  describe "#split_changed" do
    it "partitions changed paths into test files and source files" do
      test_files, source_files = flow.split_changed(
        %w[spec/models/player_spec.rb app/models/player.rb test/x_test.rb lib/util.rb]
      )
      expect(test_files).to contain_exactly("spec/models/player_spec.rb", "test/x_test.rb")
      expect(source_files).to contain_exactly("app/models/player.rb", "lib/util.rb")
    end
  end

  describe "#framework_of" do
    it "detects RSpec by the [i:j] id and Minitest by Class#test" do
      expect(flow.framework_of("./spec/a_spec.rb[1:1]")).to eq("rspec")
      expect(flow.framework_of("PlayerTest#test_a")).to eq("minitest")
    end
  end

  describe "#group_examples_by_runner" do
    it "buckets ids by framework" do
      groups = flow.group_examples_by_runner(["./spec/a_spec.rb[1:1]", "PlayerTest#test_a"])
      expect(groups["rspec"]).to eq(["./spec/a_spec.rb[1:1]"])
      expect(groups["minitest"]).to eq(["PlayerTest#test_a"])
    end
  end

  describe "#already_ran_examples" do
    it "collects the RSpec keys belonging to a changed test file by prefix" do
      map = {
        version: 1,
        "./spec/a_spec.rb[1:1]" => { "app/a.rb" => ["A#m"] },
        "./spec/a_spec.rb[1:2]" => { "app/a.rb" => ["A#n"] },
        "./spec/b_spec.rb[1:1]" => { "app/b.rb" => ["B#m"] }
      }
      expect(flow.already_ran_examples(map, ["spec/a_spec.rb"]))
        .to contain_exactly("./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[1:2]")
    end
  end
end
