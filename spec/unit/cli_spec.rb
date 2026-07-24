# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "testalaria/cli"

RSpec.describe Testalaria::CLI do
  def load_yaml(str)
    Psych.respond_to?(:unsafe_load) ? Psych.unsafe_load(str) : Psych.load(str)
  end

  # `run` constructs a real Git and Flow internally (no runner seam), so we stub
  # both — otherwise it would shell out to the configured suite command. This
  # exercises the CLI's own wiring: config -> report -> artifact -> exit status.
  describe ".run" do
    let(:selection) do
      Testalaria::Selector::Result.new(
        full_run: false, trigger: nil,
        example_reasons: {
          "e1" => [Testalaria::Selector::Reason.new(
            rule: "method_match", file: "app/models/player.rb", method: "Player#fn_one"
          )]
        },
        uncovered_files: [], escalations: [], test_files: [], file_reasons: {}
      )
    end

    def build_outcome(exit_status:)
      Testalaria::Flow::Outcome.new(
        full_run: false, trigger: nil, selection: selection,
        suites: [Testalaria::Runner::Result.new(exit_status: exit_status, stdout: "")],
        examples_run: ["e1"], map_before: {},
        map_after: { version: 1, "e1" => { "app/models/player.rb" => ["Player#fn_one"] } },
        changed_test_files: [], changed_source_files: ["app/models/player.rb"]
      )
    end

    def write_config
      path = File.join(@dir, ".testalaria.config.yml")
      File.write(path, <<~YAML)
        map_path: .testalaria.yml
        target_branch: origin/main
        runners:
          rspec:
            command: rspec
            pattern: "spec/**/*_spec.rb"
      YAML
      path
    end

    around do |example|
      keys = %w[TARGET_BRANCH VERBOSE VERBOSE_SMALL VERBOSE_BIG]
      saved = keys.to_h { |k| [k, ENV[k]] }
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    it "writes the artifact, prints the summary, and returns exit status 0" do
      allow(Testalaria::Git).to receive(:new).and_return(double(head_sha: "HEADSHA"))
      allow(Testalaria::Flow).to receive(:new).and_return(double(run: build_outcome(exit_status: 0)))
      out = StringIO.new
      artifact = File.join(@dir, "report.yml")

      status = described_class.run(config_path: write_config, out: out, artifact_path: artifact)

      expect(status).to eq(0)
      expect(out.string).to include("1 of 1 examples selected")
      written = load_yaml(File.read(artifact))
      expect(written["version"]).to eq(1)
      expect(written["head"]).to eq("HEADSHA")
    end

    it "returns a non-zero status when a suite failed" do
      allow(Testalaria::Git).to receive(:new).and_return(double(head_sha: "HEADSHA"))
      allow(Testalaria::Flow).to receive(:new).and_return(double(run: build_outcome(exit_status: 1)))

      status = described_class.run(
        config_path: write_config, out: StringIO.new, artifact_path: File.join(@dir, "r.yml")
      )
      expect(status).to eq(1)
    end

    it "appends a small selection trace (rule only) when VERBOSE=1" do
      ENV["VERBOSE"] = "1"
      allow(Testalaria::Git).to receive(:new).and_return(double(head_sha: "HEADSHA"))
      allow(Testalaria::Flow).to receive(:new).and_return(double(run: build_outcome(exit_status: 0)))
      out = StringIO.new

      described_class.run(config_path: write_config, out: out, artifact_path: File.join(@dir, "r.yml"))
      expect(out.string).to include("e1 <- method_match")
      expect(out.string).not_to include("app/models/player.rb Player#fn_one") # small omits the location
    end

    it "appends a big selection trace (rule + file/method) when VERBOSE_BIG=1" do
      ENV["VERBOSE_BIG"] = "1"
      allow(Testalaria::Git).to receive(:new).and_return(double(head_sha: "HEADSHA"))
      allow(Testalaria::Flow).to receive(:new).and_return(double(run: build_outcome(exit_status: 0)))
      out = StringIO.new

      described_class.run(config_path: write_config, out: out, artifact_path: File.join(@dir, "r.yml"))
      expect(out.string).to include("e1 <- method_match (app/models/player.rb Player#fn_one)")
    end

    it "raises ConfigError when the config file is missing" do
      expect do
        described_class.run(config_path: File.join(@dir, "nope.yml"), out: StringIO.new)
      end.to raise_error(Testalaria::ConfigError)
    end
  end

  # `lint` only reads files and scans them — no subprocess — so it runs for real
  # against a repo built in a tmpdir we chdir into.
  describe ".lint" do
    around do |example|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { example.run }
      end
    end

    def write_config
      File.write(".testalaria.config.yml", <<~YAML)
        map_path: .testalaria.yml
        runners:
          rspec:
            command: rspec
            pattern: "spec/**/*_spec.rb"
      YAML
    end

    it "prints each finding with its exposure count and a total, returning 0" do
      write_config
      FileUtils.mkdir_p("app/models")
      File.write("app/models/player.rb", "class Player\n  def clock\n    Time.now\n  end\nend\n")
      File.write(".testalaria.yml", Testalaria::Map.dump(
        version: 1,
        "./spec/player_spec.rb[1:1]" => { "app/models/player.rb" => ["Player#clock"] }
      ))

      out = StringIO.new
      status = described_class.lint(config_path: ".testalaria.config.yml", out: out)

      expect(status).to eq(0)
      expect(out.string).to include("WARN app/models/player.rb:3 Time.now (1 exposed)")
      expect(out.string).to include("testalaria: 1 nondeterminism finding(s)")
    end

    it "excludes test files from the scan" do
      write_config
      FileUtils.mkdir_p("spec/models")
      # A nondeterminism pattern living in a *test* file must not be reported.
      File.write("spec/models/player_spec.rb", "RSpec.describe Player do\n  it { Time.now }\nend\n")
      File.write(".testalaria.yml", Testalaria::Map.dump(version: 1))

      out = StringIO.new
      described_class.lint(config_path: ".testalaria.config.yml", out: out)
      expect(out.string).to include("testalaria: 0 nondeterminism finding(s)")
    end

    it "reports zero findings for a clean repo" do
      write_config
      FileUtils.mkdir_p("app")
      File.write("app/clean.rb", "class Clean\n  def go\n    1\n  end\nend\n")
      File.write(".testalaria.yml", Testalaria::Map.dump(version: 1))

      out = StringIO.new
      expect(described_class.lint(config_path: ".testalaria.config.yml", out: out)).to eq(0)
      expect(out.string).to include("testalaria: 0 nondeterminism finding(s)")
    end
  end
end
