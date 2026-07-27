# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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

  # The source-parsing seam: how HEAD/base contents become DefIndex objects.
  # Unparseable source (a syntax error, or left-over merge-conflict markers) is
  # rescued to nil, which the selector then reads as "file absent on that side".
  describe "#changed_source (parse seam)" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    def flow_with(files_at: {}, hunks: {})
      described_class.new(
        config: config,
        git: FakeGit.new(files_at: files_at, hunks: hunks),
        runner: Testalaria::Runner.new(process: FakeRunner.new),
        store: FakeMapStore.new
      )
    end

    it "treats an unparseable HEAD (left-over conflict markers) as a deleted file" do
      valid_base = "class Player\n  def fn_one\n    1\n  end\nend\n"
      File.write("player.rb", <<~CONFLICTED)
        class Player
        <<<<<<< HEAD
          def fn_one; 1; end
        =======
          def fn_one; 2; end
        >>>>>>> branch
        end
      CONFLICTED
      flow = flow_with(files_at: { ["BASE", "player.rb"] => valid_base },
                       hunks: { "player.rb" => [3..3] })

      cs = flow.send(:changed_source, "BASE", "player.rb")
      expect(cs.head_index).to be_nil        # -> selector routes it through handle_deleted_file
      expect(cs.base_index).not_to be_nil
    end

    it "leaves base_index nil for a newly added file (absent at the base)" do
      File.write("newbie.rb", "class Newbie\n  def go; end\nend\n")
      flow = flow_with(hunks: { "newbie.rb" => [1..2] }) # file_at returns nil at base

      cs = flow.send(:changed_source, "BASE", "newbie.rb")
      expect(cs.base_index).to be_nil
      expect(cs.head_index).not_to be_nil
    end

    it "leaves head_index nil when the file no longer exists at HEAD" do
      flow = flow_with(files_at: { ["BASE", "gone.rb"] => "class Gone\nend\n" })

      cs = flow.send(:changed_source, "BASE", "gone.rb")
      expect(cs.head_index).to be_nil
      expect(cs.base_index).not_to be_nil
    end
  end

  describe "#plan" do
    around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

    let(:seeded_map) do
      {
        version: 1,
        "./spec/player_spec.rb[1:1]" => { "app/models/player.rb" => ["Player#fn_one"] },
        "./spec/player_spec.rb[1:2]" => { "app/models/player.rb" => ["Player#fn_two"] }
      }
    end

    let(:process) { FakeRunner.new }

    def plan_flow(cfg: config, changed_files: [], hunks: {})
      git = FakeGit.new(merge_base: "BASE", changed_files: changed_files, hunks: hunks)
      described_class.new(
        config: cfg, git: git,
        runner: Testalaria::Runner.new(process: process),
        store: FakeMapStore.new(initial: seeded_map)
      )
    end

    it "lists the selected example ids and runs nothing" do
      FileUtils.mkdir_p("app/models")
      File.write("app/models/player.rb", "class Player\n  def fn_one\n    11\n  end\n  def fn_two\n    2\n  end\nend\n")
      flow = plan_flow(changed_files: ["app/models/player.rb"], hunks: { "app/models/player.rb" => [3..3] })

      plan = flow.plan

      expect(plan.full_run).to be(false)
      expect(plan.example_ids).to contain_exactly("./spec/player_spec.rb[1:1]")
      expect(process.calls).to eq([]) # selection only — nothing executed
    end

    it "signals a full run via the plan flag" do
      cfg = Testalaria::Config.new(
        "runners" => { "rspec" => { "command" => "rspec", "pattern" => "spec/**/*_spec.rb" } },
        "full_run_triggers" => ["Gemfile"]
      )
      flow = plan_flow(cfg: cfg, changed_files: ["Gemfile"], hunks: {})

      plan = flow.plan
      expect(plan.full_run).to be(true)
      expect(plan.trigger).to eq("Gemfile")
    end
  end

  describe "#changed_constants" do
    def source(path, body, hunks)
      Testalaria::Selector::ChangedSource.new(
        path: path, hunks: hunks,
        head_index: Testalaria::DefIndex.build(body), base_index: nil
      )
    end

    it "extracts constants whose assignment lines are in the diff" do
      cs = source("app/x.rb", "class X\n  LIMIT = 1\n  def go; end\nend\n", [2..2])
      expect(flow.send(:changed_constants, [cs])).to eq(["LIMIT"])
    end

    it "ignores constants whose assignment lines are not in the diff" do
      cs = source("app/x.rb", "class X\n  LIMIT = 1\n  def go\n    1\n  end\nend\n", [3..3])
      expect(flow.send(:changed_constants, [cs])).to eq([])
    end
  end
end
