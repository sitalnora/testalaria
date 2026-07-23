# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Report do
  Reason = Testalaria::Selector::Reason

  let(:selection) do
    Testalaria::Selector::Result.new(
      full_run: false, trigger: nil,
      example_reasons: {
        "e1" => [Reason.new(rule: "method_match", file: "app/models/player.rb", method: "Player#fn_one")]
      },
      uncovered_files: ["app/services/new_thing.rb"],
      escalations: [
        Reason.new(rule: "file_escalation", file: "app/models/player.rb",
                   cause: "new_method", method: "Player#apply_bonus")
      ],
      test_files: [],
      file_reasons: {}
    )
  end

  let(:map_after) do
    {
      commit: "abc123", version: 1,
      "e1" => { "app/models/player.rb" => ["Player#fn_one"] },
      "e2" => { "app/models/team.rb" => ["Team#m"], "app/models/player.rb" => ["Player#fn_two"] }
    }
  end

  let(:outcome) do
    Testalaria::Flow::Outcome.new(
      full_run: false, trigger: nil, selection: selection, suites: [],
      examples_run: ["e1"], map_before: {}, map_after: map_after,
      changed_test_files: [], changed_source_files: ["app/models/player.rb"]
    )
  end

  subject(:report) { described_class.new(outcome, head: "HEADSHA") }

  it "produces a v1 artifact with the map commit and head" do
    art = report.artifact
    expect(art["version"]).to eq(1)
    expect(art["map_commit"]).to eq("abc123")
    expect(art["head"]).to eq("HEADSHA")
  end

  it "summarizes selection counts" do
    sel = report.artifact["selection"]
    expect(sel["total_known_examples"]).to eq(2)
    expect(sel["examples_selected"]).to eq(1)
    expect(sel["full_run_triggered"]).to be(false)
  end

  it "groups tested examples by the file that selected them" do
    expect(report.artifact["tested"]["app/models/player.rb"]).to include("e1")
  end

  it "reports uncovered files and co-executed neighbors" do
    affected = report.artifact["affected"]
    expect(affected["uncovered_changed_files"]).to eq(["app/services/new_thing.rb"])
    expect(affected["co_executed_neighbors"]).to include("app/models/team.rb")
  end

  it "lists new methods with no coverage as untested new code (fallback)" do
    expect(report.artifact["untested_new_code"]).to include(
      "file" => "app/models/player.rb", "method" => "Player#apply_bonus"
    )
  end

  context "with a live coverage digest (real diff coverage)" do
    let(:head_source) do
      # apply_bonus (added, lines 8-10) never executed; fn_one (2-3) did.
      "class Player\n  def fn_one\n    1\n  end\n  def fn_two\n    2\n  end\n  def apply_bonus\n    99\n  end\nend\n"
    end

    let(:changed_source) do
      Testalaria::Selector::ChangedSource.new(
        path: "app/models/player.rb",
        hunks: [3..3, 8..9], # edited fn_one body + added apply_bonus (def+body)
        head_index: Testalaria::DefIndex.build(head_source),
        base_index: nil
      )
    end

    let(:outcome) do
      Testalaria::Flow::Outcome.new(
        full_run: false, trigger: nil, selection: selection, suites: [],
        examples_run: ["e1"], map_before: {}, map_after: map_after,
        changed_test_files: [], changed_source_files: ["app/models/player.rb"],
        changed_sources: [changed_source],
        executed_lines: { "app/models/player.rb" => [2, 3] } # only fn_one ran
      )
    end

    it "reports added lines no test executed, resolved to the method" do
      untested = report.artifact["untested_new_code"]
      expect(untested).to contain_exactly(
        "file" => "app/models/player.rb", "method" => "Player#apply_bonus", "lines" => [8, 9]
      )
    end
  end

  it "emits a selection trace keyed by example" do
    trace = report.artifact["selection_trace"]
    expect(trace["e1"].first["rule"]).to eq("method_match")
  end

  it "renders a terminal summary" do
    expect(report.terminal).to include("1 of 2 examples selected")
    expect(report.terminal).to include("exposed (no known coverage): app/services/new_thing.rb")
  end

  it "lists escalations and untested new code in the terminal output" do
    text = report.terminal
    expect(text).to include("escalated app/models/player.rb -> new_method")
    expect(text).to include("untested new code: Player#apply_bonus (app/models/player.rb)")
  end

  it "appends the per-example selection trace under VERBOSE" do
    expect(report.terminal(verbose: true)).to include("e1 <- method_match")
  end

  context "when the outcome is a full run" do
    let(:full_outcome) do
      Testalaria::Flow::Outcome.new(
        full_run: true, trigger: "Gemfile", selection: selection, suites: [],
        examples_run: [], map_before: {}, map_after: map_after,
        changed_test_files: [], changed_source_files: []
      )
    end

    subject(:report) { described_class.new(full_outcome, head: "HEADSHA") }

    it "reports the trigger in both the artifact and the terminal" do
      expect(report.artifact["selection"]["full_run_triggered"]).to be(true)
      expect(report.artifact["selection"]["trigger"]).to eq("Gemfile")
      expect(report.terminal).to include("full run triggered by Gemfile")
    end
  end
end
