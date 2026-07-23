# frozen_string_literal: true

require "spec_helper"

# Phase 0 gate: the gem loads, the namespace and error hierarchy exist, and the
# support seams are wired. Real behaviour arrives in later phases.
RSpec.describe Testalaria do
  it "defines a semantic version" do
    expect(Testalaria::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  it "roots every error at Testalaria::Error" do
    [Testalaria::OneshotCoverageError,
     Testalaria::ConfigError,
     Testalaria::ParseError,
     Testalaria::GitError].each do |klass|
      expect(klass.ancestors).to include(Testalaria::Error)
    end
  end

  describe "test support seams" do
    it "FakeGit answers the Git interface from canned data" do
      git = FakeGit.new(merge_base: "abc", changed_files: ["a.rb"],
                        hunks: { "a.rb" => [2..3] },
                        files_at: { ["abc", "a.rb"] => "old" })
      expect(git.merge_base("origin/main")).to eq("abc")
      expect(git.changed_files("abc")).to eq(["a.rb"])
      expect(git.hunks("abc", "a.rb")).to eq([2..3])
      expect(git.file_at("abc", "a.rb")).to eq("old")
    end

    it "FakeRunner records calls and returns scripted results" do
      runner = FakeRunner.new(scripted: { exit_status: 1, stdout: "boom" })
      result = runner.run(%w[rspec spec/a_spec.rb], env: { "TESTALARIA" => "1" })
      expect(result.exit_status).to eq(1)
      expect(runner.calls.first[:env]).to eq("TESTALARIA" => "1")
    end

    it "FakeAdapter drives an example lifecycle" do
      adapter = FakeAdapter.new
      adapter.example("spec/a_spec.rb[1:1]") { { "a.rb" => [1, 2] } }
      expect(adapter.started).to eq(["spec/a_spec.rb[1:1]"])
      expect(adapter.finished).to eq([["spec/a_spec.rb[1:1]", { "a.rb" => [1, 2] }]])
    end
  end
end
