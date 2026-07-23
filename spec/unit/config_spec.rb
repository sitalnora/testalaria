# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::Config do
  def write_config(dir, body)
    path = File.join(dir, ".testalaria.config.yml")
    File.write(path, body)
    path
  end

  it "loads runners, patterns, target branch and triggers" do
    Dir.mktmpdir do |dir|
      path = write_config(dir, <<~YAML)
        map_path: .testalaria.yml
        target_branch: origin/main
        runners:
          rspec:
            command: "bundle exec rspec"
            pattern: "spec/**/*_spec.rb"
          minitest:
            command: "bundle exec rails test"
            pattern: "test/**/*_test.rb"
        full_run_triggers:
          - Gemfile.lock
      YAML
      config = described_class.load(path)
      expect(config.target_branch).to eq("origin/main")
      expect(config.runners.map(&:name)).to contain_exactly("rspec", "minitest")
      expect(config.full_run_triggers).to eq(["Gemfile.lock"])
    end
  end

  it "matches a test file to its runner by pattern" do
    config = described_class.new(
      "runners" => { "rspec" => { "command" => "rspec", "pattern" => "spec/**/*_spec.rb" } }
    )
    expect(config.runner_for("spec/models/player_spec.rb")&.name).to eq("rspec")
    expect(config.test_file?("app/models/player.rb")).to be(false)
  end

  it "raises a typed ConfigError when the file is missing" do
    expect { described_class.load("/no/such/config.yml") }.to raise_error(Testalaria::ConfigError)
  end

  it "raises when no runners are configured" do
    expect { described_class.new("runners" => {}) }.to raise_error(Testalaria::ConfigError)
  end

  it "applies defaults for map_path, target_branch, and simplecov" do
    config = described_class.new(
      "runners" => { "rspec" => { "command" => "rspec", "pattern" => "spec/**/*_spec.rb" } }
    )
    expect(config.map_path).to eq(Testalaria::MapStore::DEFAULT_PATH)
    expect(config.target_branch).to eq("origin/main")
    expect(config.simplecov).to eq("auto")
  end

  it "honors an explicit simplecov setting" do
    config = described_class.new(
      "runners" => { "rspec" => { "command" => "rspec", "pattern" => "spec/**/*_spec.rb" } },
      "simplecov" => false
    )
    expect(config.simplecov).to be(false)
  end

  it "raises ConfigError when the config file is not a mapping" do
    Dir.mktmpdir do |dir|
      path = write_config(dir, "- 1\n- 2\n")
      expect { described_class.load(path) }.to raise_error(Testalaria::ConfigError)
    end
  end

  it "matches a deeply nested test path via the runner glob" do
    config = described_class.new(
      "runners" => { "minitest" => { "command" => "rails test", "pattern" => "test/**/*_test.rb" } }
    )
    expect(config.runner_for("test/models/deep/player_test.rb")&.name).to eq("minitest")
    expect(config.test_file?("test/models/player.rb")).to be(false)
  end
end
