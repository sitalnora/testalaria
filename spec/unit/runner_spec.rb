# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "shellwords"

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

  it "passes RSpec example ids through as targets, shell-safe for [i:j] globs" do
    runner.run_examples(rspec, ["./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[1:2]"])
    # After the shell parses the command, rspec receives the ids intact.
    argv = Shellwords.split(process.calls.first[:cmd])
    expect(argv).to eq(["bundle", "exec", "rspec", "./spec/a_spec.rb[1:1]", "./spec/a_spec.rb[1:2]"])
  end

  it "groups Minitest example ids by file with an -n filter (pipes survive the shell)" do
    locator = Testalaria::TestLocator.new("PlayerTest" => "test/player_test.rb")
    runner.run_examples(minitest, %w[PlayerTest#test_a PlayerTest#test_b], locator: locator)
    # The `|` must reach minitest as a regex alternation, not be a shell pipe.
    argv = Shellwords.split(process.calls.first[:cmd])
    expect(argv).to include("test/player_test.rb", "-n", "/test_a|test_b/")
  end

  it "combines several files into ONE -n filter in a single invocation" do
    # Regression: a -n per file means Minitest keeps only the last -n and runs
    # just that file. All files must load under one combined filter, one boot.
    locator = Testalaria::TestLocator.new(
      "Atest" => "test/a_test.rb", "Btest" => "test/b_test.rb"
    )
    runner.run_examples(minitest, %w[Atest#test_one Btest#test_two], locator: locator)

    expect(process.calls.size).to eq(1)
    argv = Shellwords.split(process.calls.first[:cmd])
    expect(argv).to include("test/a_test.rb", "test/b_test.rb")
    expect(argv.count("-n")).to eq(1)
    expect(argv.last).to eq("/test_one|test_two/")
  end

  it "merges caller env over the TESTALARIA base flag" do
    runner.run_files(rspec, ["spec/a_spec.rb"], env: { "RAILS_ENV" => "test" })
    env = process.calls.first[:env]
    expect(env).to include("TESTALARIA" => "1", "RAILS_ENV" => "test")
  end

  it "issues a bare command with no targets for a full run" do
    runner.run_files(rspec, [])
    expect(process.calls.first[:cmd]).to eq("bundle exec rspec")
  end

  it "skips Minitest ids whose class has no known file" do
    runner.run_examples(minitest, %w[Unknown#test_a], locator: Testalaria::TestLocator.new)
    expect(process.calls.first[:cmd]).to eq("bundle exec rails test")
  end

  it "regex-escapes metacharacters in Minitest test names (and stays shell-safe)" do
    locator = Testalaria::TestLocator.new("PlayerTest" => "test/player_test.rb")
    runner.run_examples(minitest, ["PlayerTest#test_a?"], locator: locator)
    # Regexp.escape turns `?` into `\?` inside the /.../; the shell delivers it intact.
    argv = Shellwords.split(process.calls.first[:cmd])
    expect(argv).to include("-n", '/test_a\?/')
  end

  describe Testalaria::TestLocator do
    it ".from_glob maps class names to their file, skipping unparseable ones" do
      Dir.mktmpdir do |dir|
        good = File.join(dir, "player_test.rb")
        File.write(good, "class PlayerTest\n  def test_x; end\nend\n")
        File.write(File.join(dir, "broken_test.rb"), "class Broken(\n")

        locator = described_class.from_glob([File.join(dir, "*_test.rb")])
        expect(locator.file_for("PlayerTest")).to eq(good)
        expect(locator.file_for("Broken")).to be_nil
      end
    end
  end
end
