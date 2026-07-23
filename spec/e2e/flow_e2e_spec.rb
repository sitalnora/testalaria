# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

# L4 — end-to-end flow. Builds a real git repo with a seeded map, scripts a
# synthetic PR (edit one method), and drives the real Flow with real git and a
# spy runner. Asserts which example the flow selects and what command it issues,
# without executing a real suite (that is L3). Tagged :integration.
RSpec.describe "testalaria:run flow", :integration do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def git(*args)
    _o, err, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?
  end

  let(:base_source) do
    "class Player\n  def fn_one\n    1\n  end\n  def fn_two\n    2\n  end\nend\n"
  end

  before do
    FileUtils.mkdir_p(File.join(@dir, "app/models"))
    File.write("app/models/player.rb", base_source)

    File.write(".testalaria.config.yml", <<~YAML)
      map_path: .testalaria.yml
      target_branch: main
      runners:
        rspec:
          command: "rspec"
          pattern: "spec/**/*_spec.rb"
    YAML

    File.write(".testalaria.yml", Testalaria::Map.dump(
      version: 1,
      "./spec/player_spec.rb[1:1]" => { "app/models/player.rb" => ["Player#fn_one"] },
      "./spec/player_spec.rb[1:2]" => { "app/models/player.rb" => ["Player#fn_two"] }
    ))

    git "init", "-q", "-b", "main"
    git "config", "user.email", "t@example.com"
    git "config", "user.name", "Test"
    git "add", "."
    git "commit", "-q", "-m", "base"

    git "checkout", "-q", "-b", "feature"
    # Edit only fn_one's body (line 3).
    File.write("app/models/player.rb", base_source.sub("    1\n", "    11\n"))
    git "add", "."
    git "commit", "-q", "-m", "edit fn_one"
  end

  it "selects only fn_one's example and runs it" do
    process = FakeRunner.new(scripted: { exit_status: 0, stdout: "" })
    config = Testalaria::Config.load(".testalaria.config.yml")
    flow = Testalaria::Flow.new(
      config: config,
      git: Testalaria::Git.new(dir: @dir),
      runner: Testalaria::Runner.new(process: process)
    )

    outcome = flow.run

    expect(outcome.full_run).to be(false)
    expect(outcome.selection.example_reasons.keys).to contain_exactly("./spec/player_spec.rb[1:1]")

    cmd = process.calls.map { |c| c[:cmd] }.join(" | ")
    expect(cmd).to include("./spec/player_spec.rb[1:1]")
    expect(cmd).not_to include("[1:2]")
    expect(Testalaria::Flow.exit_status(outcome)).to eq(0)
  end
end
