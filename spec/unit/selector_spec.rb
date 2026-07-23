# frozen_string_literal: true

require "spec_helper"

RSpec.describe Testalaria::Selector do
  DI = Testalaria::DefIndex
  CS = Testalaria::Selector::ChangedSource

  # A two-method model file used across scenarios. fn_one: 2..3, fn_two: 5..6.
  let(:player_src) do
    <<~RUBY
      class Player
        def fn_one
          1
        end
        def fn_two
          2
        end
      end
    RUBY
  end

  # Same file with a class-body macro on line 2, defs shifted down.
  let(:player_with_macro) do
    <<~RUBY
      class Player
        validates :name
        def fn_one
          1
        end
        def fn_two
          2
        end
      end
    RUBY
  end

  # Same file plus a brand-new fn_three (8..9).
  let(:player_plus_new) do
    <<~RUBY
      class Player
        def fn_one
          1
        end
        def fn_two
          2
        end
        def fn_three
          3
        end
      end
    RUBY
  end

  let(:path) { "app/models/player.rb" }

  let(:map) do
    {
      version: 1,
      "e1" => { path => ["Player#fn_one"] },
      "e2" => { path => ["Player#fn_two"] },
      "e3" => { path => ["Player#fn_one", "Player#fn_two"] }
    }
  end

  def selector(triggers: [], stub_index: nil)
    described_class.new(map: map, full_run_triggers: triggers, stub_index: stub_index)
  end

  def source(head, base = head, hunks:)
    CS.new(path: path, hunks: hunks,
           head_index: head && DI.build(head),
           base_index: base && DI.build(base))
  end

  it "single-method edit selects only that method's examples" do
    result = selector.select(changed_source: [source(player_src, hunks: [3..3])])
    expect(result.example_reasons.keys).to contain_exactly("e1", "e3")
    expect(result.full_run).to be(false)
    expect(result.example_reasons["e1"].first.rule).to eq("method_match")
  end

  it "edit spanning two methods selects both" do
    result = selector.select(changed_source: [source(player_src, hunks: [3..5])])
    expect(result.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
  end

  it "class-body (toplevel) edit escalates to every example of the file" do
    result = selector.select(changed_source: [source(player_with_macro, hunks: [2..2])])
    expect(result.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    expect(result.escalations.map(&:cause)).to include("toplevel_change")
  end

  it "new method escalates to file-level (new_method)" do
    result = selector.select(
      changed_source: [source(player_plus_new, player_src, hunks: [8..8])]
    )
    expect(result.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    expect(result.escalations.map(&:cause)).to include("new_method")
  end

  it "deleted method selects the examples that ran it (merge-base parse)" do
    # HEAD removed fn_two; base still had it. Hunk touches fn_one.
    head_only_one = <<~RUBY
      class Player
        def fn_one
          1
        end
      end
    RUBY
    result = selector.select(
      changed_source: [source(head_only_one, player_src, hunks: [3..3])]
    )
    # fn_one via method_match (e1,e3) + fn_two deleted (e2,e3)
    expect(result.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
  end

  it "rename (delete old + add new) double-escalates the file" do
    head_renamed = <<~RUBY
      class Player
        def fn_uno
          1
        end
        def fn_two
          2
        end
      end
    RUBY
    result = selector.select(
      changed_source: [source(head_renamed, player_src, hunks: [2..2])]
    )
    expect(result.escalations.map(&:cause)).to include("rename")
  end

  it "changed file absent from the map is reported uncovered, selects nothing" do
    other = CS.new(path: "app/services/new_thing.rb", hunks: [1..1],
                   head_index: DI.build("class NewThing\n  def go; end\nend\n"),
                   base_index: nil)
    result = selector.select(changed_source: [other])
    expect(result.example_reasons).to be_empty
    expect(result.uncovered_files).to eq(["app/services/new_thing.rb"])
  end

  it "a full-run trigger short-circuits to full_run" do
    result = selector(triggers: ["Gemfile.lock", "config/**"])
             .select(changed_paths: ["config/initializers/x.rb"])
    expect(result.full_run).to be(true)
    expect(result.trigger).to eq("config/initializers/x.rb").or eq("config/**")
  end

  it "a changed test file is queued to run with changed_test_file provenance" do
    result = selector.select(changed_test: ["spec/player_spec.rb"])
    expect(result.test_files).to include("spec/player_spec.rb")
    expect(result.file_reasons["spec/player_spec.rb"].map(&:rule)).to include("changed_test_file")
  end

  it "stub_match adds blind test files when a changed method is stubbed" do
    stub_index = Testalaria::StubIndex.build(
      "spec/blind_spec.rb" => "allow(x).to receive(:fn_one)\n"
    )
    result = selector(stub_index: stub_index)
             .select(changed_source: [source(player_src, hunks: [3..3])])
    expect(result.test_files).to include("spec/blind_spec.rb")
    expect(result.file_reasons["spec/blind_spec.rb"].map(&:rule)).to include("stub_match")
  end

  it "keeps multiple provenance routes for one example (monotone union)" do
    # e3 is selected by both fn_one and fn_two method matches.
    result = selector.select(changed_source: [source(player_src, hunks: [3..3, 6..6])])
    expect(result.example_reasons["e3"].map(&:method)).to include("Player#fn_one", "Player#fn_two")
  end
end
