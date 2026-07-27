# frozen_string_literal: true

require "spec_helper"

# Exhaustive coverage of how the Selector routes every shape of change:
# source vs test files, method-level matches, file-level escalations (new
# method / toplevel / dynamic / rename / file change / file deleted), deleted
# methods, stub back-fill, full-run triggers, uncovered files, and the conflict
# cases where one example is reached by several routes at once.
#
# Fixture geometry (line numbers matter — gap lines like `end` resolve to
# TOPLEVEL, which is a *different* branch than a method hit):
#
#   class Player   #1   (toplevel)
#     def fn_one   #2   \
#       1          #3   / Player#fn_one  -> 2..3
#     end          #4   (toplevel gap)
#     def fn_two   #5   \
#       2          #6   / Player#fn_two  -> 5..6
#     end          #7   (toplevel gap)
#   end            #8   (toplevel)
RSpec.describe Testalaria::Selector do
  let(:path) { "app/models/player.rb" }

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

  # player_src + a brand-new fn_three on lines 8..9.
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

  # A macro on the class body (line 2), defs shifted down.
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

  let(:map) do
    {
      version: 1,
      "e1" => { path => ["Player#fn_one"] },
      "e2" => { path => ["Player#fn_two"] },
      "e3" => { path => ["Player#fn_one", "Player#fn_two"] }
    }
  end

  # map_data is a keyword so a symbol-keyed map hash isn't mistaken for kwargs.
  def selector(map_data: map, triggers: [], stub_index: nil, const_index: nil)
    described_class.new(
      map: map_data, full_run_triggers: triggers,
      stub_index: stub_index, const_index: const_index
    )
  end

  # Build a ChangedSource; head/base may be nil (deleted / added file).
  def changed(file, head, base = head, hunks:)
    Testalaria::Selector::ChangedSource.new(
      path: file, hunks: hunks,
      head_index: head && Testalaria::DefIndex.build(head),
      base_index: base && Testalaria::DefIndex.build(base)
    )
  end

  def causes(result)
    result.escalations.map(&:cause)
  end

  # --- source file: method-level selection -------------------------------

  describe "source change resolving to a single method" do
    it "selects only that method's examples (body line)" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e3")
    end

    it "selects the same set from the def line as from the body line" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [2..2])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e3")
    end

    it "selects fn_two's examples for an edit in its body" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [6..6])])
      expect(r.example_reasons.keys).to contain_exactly("e2", "e3")
    end

    it "tags the reason as method_match carrying the method name" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3])])
      reason = r.example_reasons["e1"].first
      expect(reason.rule).to eq("method_match")
      expect(reason.method).to eq("Player#fn_one")
    end

    it "does not escalate for a pure method match" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.escalations).to be_empty
      expect(r.full_run).to be(false)
    end
  end

  describe "source change spanning multiple methods" do
    it "selects both methods via method_match when hunks avoid gap lines" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3, 6..6])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(r.escalations).to be_empty
      expect(r.example_reasons.values.flatten.map(&:rule).uniq).to eq(["method_match"])
    end

    it "escalates to the whole file when a hunk crosses a gap (end) line" do
      # lines 3..5 include line 4 (`end`), which resolves to TOPLEVEL.
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..5])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(causes(r)).to include("toplevel_change")
    end

    it "unions provenance when one example is hit by two methods" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3, 6..6])])
      expect(r.example_reasons["e3"].map(&:method)).to include("Player#fn_one", "Player#fn_two")
    end
  end

  # --- source file: new methods (file-level fallback) --------------------

  describe "a newly added method" do
    it "escalates the file (new_method) and selects every example" do
      r = selector.select(changed_source: [changed(path, player_plus_new, player_src, hunks: [8..8])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(causes(r)).to include("new_method")
    end

    it "records the new method name on the escalation reason" do
      r = selector.select(changed_source: [changed(path, player_plus_new, player_src, hunks: [8..8])])
      esc = r.escalations.find { |e| e.cause == "new_method" }
      expect(esc.method).to eq("Player#fn_three")
    end

    it "selects examples via file_escalation reasons (not method_match)" do
      r = selector.select(changed_source: [changed(path, player_plus_new, player_src, hunks: [8..8])])
      expect(r.example_reasons["e2"].map(&:rule)).to eq(["file_escalation"])
    end

    it "combines a method_match for an edited method with a new_method escalation" do
      r = selector.select(changed_source: [changed(path, player_plus_new, player_src, hunks: [3..3, 8..8])])
      rules = r.example_reasons["e1"].map(&:rule)
      expect(rules).to include("method_match")
      expect(causes(r)).to include("new_method")
    end

    it "records a new_method escalation but selects nothing when the file has no examples" do
      ghost = "app/models/ghost.rb"
      base = "class Ghost\n  def a\n    1\n  end\nend\n"
      head = "class Ghost\n  def a\n    1\n  end\n  def b\n    2\n  end\nend\n"
      r = selector.select(changed_source: [changed(ghost, head, base, hunks: [5..5])])
      expect(r.example_reasons).to be_empty
      expect(causes(r)).to include("new_method")
    end
  end

  # --- source file: toplevel / class-body changes ------------------------

  describe "a class-body (toplevel) change" do
    it "escalates as toplevel_change over every example" do
      r = selector.select(changed_source: [changed(path, player_with_macro, hunks: [2..2])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(causes(r)).to include("toplevel_change")
    end

    it "treats an edit on the class line the same way" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [1..1])])
      expect(causes(r)).to include("toplevel_change")
    end

    it "is not labelled dynamic_def when the file has no metaprogramming" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [1..1])])
      expect(causes(r)).to include("toplevel_change")
      expect(causes(r)).not_to include("dynamic_def")
    end
  end

  # --- dynamic files fall back to file-level -----------------------------

  describe "a file with dynamic (metaprogrammed) definitions" do
    let(:define_method_src) do
      <<~RUBY
        class Player
          define_method(:x) { 1 }
        end
      RUBY
    end

    let(:class_eval_src) do
      <<~RUBY
        class Player
          class_eval "def y; end"
        end
      RUBY
    end

    it "escalates as dynamic_def rather than resolving a method" do
      r = selector.select(
        changed_source: [changed(path, define_method_src, define_method_src, hunks: [2..2])]
      )
      expect(causes(r)).to include("dynamic_def")
    end

    it "selects every example of the file on a dynamic escalation" do
      r = selector.select(
        changed_source: [changed(path, define_method_src, define_method_src, hunks: [2..2])]
      )
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    end

    it "recognizes string class_eval as dynamic" do
      r = selector.select(
        changed_source: [changed(path, class_eval_src, class_eval_src, hunks: [2..2])]
      )
      expect(causes(r)).to include("dynamic_def")
    end

    it "distinguishes dynamic_def from an ordinary toplevel_change" do
      dynamic = selector.select(
        changed_source: [changed(path, define_method_src, define_method_src, hunks: [2..2])]
      )
      static = selector.select(changed_source: [changed(path, player_with_macro, hunks: [2..2])])
      expect(causes(dynamic)).to include("dynamic_def")
      expect(causes(static)).to include("toplevel_change")
    end

    it "still records a dynamic escalation when a static file becomes dynamic" do
      # base was static (player_src), head is now define_method-based.
      r = selector.select(
        changed_source: [changed(path, define_method_src, player_src, hunks: [2..2])]
      )
      expect(causes(r)).to include("dynamic_def")
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    end

    # A file can be dynamic AND still have statically-resolvable methods. The
    # dynamic flag only forces escalation when a hunk lands on a TOPLEVEL line.
    let(:mixed_src) do
      <<~RUBY
        class Player
          def fn_one
            1
          end
          define_method(:dyn) { 2 }
        end
      RUBY
    end

    it "resolves a hunk on a static method by method_match (no dynamic escalation)" do
      r = selector.select(changed_source: [changed(path, mixed_src, mixed_src, hunks: [3..3])])
      expect(r.example_reasons["e1"].map(&:rule)).to eq(["method_match"])
      expect(causes(r)).not_to include("dynamic_def")
    end

    it "escalates dynamic_def only for a hunk on the metaprogrammed (toplevel) line" do
      r = selector.select(changed_source: [changed(path, mixed_src, mixed_src, hunks: [5..5])])
      expect(causes(r)).to include("dynamic_def")
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    end

    it "resolves the outer method of a nested-def file rather than escalating dynamic_def" do
      nested = <<~RUBY
        class Player
          def fn_one
            def inner
              1
            end
          end
        end
      RUBY
      r = selector.select(changed_source: [changed(path, nested, nested, hunks: [2..2])])
      expect(r.example_reasons["e1"].map(&:rule)).to eq(["method_match"])
      expect(causes(r)).not_to include("dynamic_def")
    end
  end

  # --- deleted methods ----------------------------------------------------

  describe "a deleted method" do
    let(:head_only_one) do
      <<~RUBY
        class Player
          def fn_one
            1
          end
        end
      RUBY
    end

    it "selects the examples that ran it, via method_match" do
      r = selector.select(changed_source: [changed(path, head_only_one, player_src, hunks: [3..3])])
      expect(r.example_reasons["e2"].map(&:rule)).to eq(["method_match"])
      expect(r.escalations).to be_empty
    end

    it "selects both the edited and the deleted method's examples" do
      r = selector.select(changed_source: [changed(path, head_only_one, player_src, hunks: [3..3])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    end

    it "ignores a deleted method that has no recorded coverage" do
      base3 = <<~RUBY
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
      head = player_src.sub("    1\n", "    111\n") # edit fn_one, drop fn_three
      r = selector.select(changed_source: [changed(path, head, base3, hunks: [3..3])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e3")
      expect(r.escalations).to be_empty
    end
  end

  # --- rename (delete old + add new) -------------------------------------

  describe "a renamed method (delete old + add new)" do
    let(:head_renamed) do
      <<~RUBY
        class Player
          def fn_uno
            1
          end
          def fn_two
            2
          end
        end
      RUBY
    end

    it "double-escalates the file as a rename" do
      r = selector.select(changed_source: [changed(path, head_renamed, player_src, hunks: [2..2])])
      expect(causes(r)).to include("rename")
    end

    it "selects every example of the file" do
      r = selector.select(changed_source: [changed(path, head_renamed, player_src, hunks: [2..2])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
    end

    it "attributes the deleted method's examples with a rename file_escalation" do
      r = selector.select(changed_source: [changed(path, head_renamed, player_src, hunks: [2..2])])
      expect(r.example_reasons["e1"]).to include(
        have_attributes(rule: "file_escalation", cause: "rename")
      )
    end

    it "is a rename (not a plain new_method) only because a method was also deleted" do
      # Same new method, but nothing deleted -> new_method, not rename.
      r = selector.select(changed_source: [changed(path, player_plus_new, player_src, hunks: [8..8])])
      expect(causes(r)).to include("new_method")
      expect(causes(r)).not_to include("rename")
    end
  end

  # --- a file deleted entirely at HEAD -----------------------------------

  describe "a source file deleted at HEAD" do
    it "escalates (file_deleted) every example that ran it" do
      r = selector.select(changed_source: [changed(path, nil, player_src, hunks: [])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(causes(r)).to include("file_deleted")
    end

    it "reports a deleted file with no coverage as uncovered, selecting nothing" do
      ghost = "app/models/ghost.rb"
      r = selector.select(changed_source: [changed(ghost, nil, "class Ghost\n  def a; end\nend\n", hunks: [])])
      expect(r.example_reasons).to be_empty
      expect(r.uncovered_files).to eq([ghost])
    end

    it "back-fills a blind test that stubbed a method of the deleted file" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:fn_one)\n")
      r = selector(stub_index: stub)
          .select(changed_source: [changed(path, nil, player_src, hunks: [])])
      expect(r.test_files).to include("spec/blind_spec.rb")
    end
  end

  # --- a newly added source file -----------------------------------------

  describe "a source file added at HEAD (absent from the map)" do
    let(:newbie) { "app/models/newbie.rb" }
    let(:newbie_src) { "class Newbie\n  def go\n    1\n  end\nend\n" }

    it "is reported uncovered (no examples, no stub)" do
      r = selector.select(changed_source: [changed(newbie, newbie_src, nil, hunks: [3..3])])
      expect(r.uncovered_files).to eq([newbie])
      expect(r.example_reasons).to be_empty
    end

    it "still records a new_method escalation for its defs" do
      r = selector.select(changed_source: [changed(newbie, newbie_src, nil, hunks: [3..3])])
      expect(causes(r)).to include("new_method")
    end
  end

  # --- no hunk detail (binary / mode change) -----------------------------

  describe "a change with no hunk detail" do
    it "widens to a file_change escalation over every example" do
      r = selector.select(changed_source: [changed(path, player_src, player_src, hunks: [])])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e2", "e3")
      expect(causes(r)).to include("file_change")
    end

    it "treats nil hunks the same as empty hunks" do
      r = selector.select(changed_source: [changed(path, player_src, player_src, hunks: nil)])
      expect(causes(r)).to include("file_change")
    end

    it "still exposes head method names for stub back-fill on a file_change" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:fn_two)\n")
      r = selector(stub_index: stub)
          .select(changed_source: [changed(path, player_src, player_src, hunks: [])])
      expect(r.test_files).to include("spec/blind_spec.rb")
    end
  end

  # --- changed test files -------------------------------------------------

  describe "changed test files" do
    it "queues the test file to run with changed_test_file provenance" do
      r = selector.select(changed_test: ["spec/player_spec.rb"])
      expect(r.test_files).to eq(["spec/player_spec.rb"])
      expect(r.file_reasons["spec/player_spec.rb"].map(&:rule)).to eq(["changed_test_file"])
    end

    it "does not add anything to example_reasons for a changed test file alone" do
      r = selector.select(changed_test: ["spec/player_spec.rb"])
      expect(r.example_reasons).to be_empty
    end

    it "queues several changed test files" do
      r = selector.select(changed_test: ["spec/a_spec.rb", "test/b_test.rb"])
      expect(r.test_files).to contain_exactly("spec/a_spec.rb", "test/b_test.rb")
    end

    it "combines a changed test file with a changed source file" do
      r = selector.select(
        changed_source: [changed(path, player_src, hunks: [3..3])],
        changed_test: ["spec/player_spec.rb"]
      )
      expect(r.test_files).to include("spec/player_spec.rb")
      expect(r.example_reasons.keys).to contain_exactly("e1", "e3")
    end
  end

  # --- full-run triggers --------------------------------------------------

  describe "full-run triggers" do
    it "short-circuits to a full run on an exact path match" do
      r = selector(triggers: ["Gemfile.lock"]).select(changed_paths: ["Gemfile.lock"])
      expect(r.full_run).to be(true)
      expect(r.trigger).to eq("Gemfile.lock")
    end

    it "matches a glob trigger" do
      r = selector(triggers: ["config/**"]).select(changed_paths: ["config/initializers/x.rb"])
      expect(r.full_run).to be(true)
    end

    it "matches a trigger reached via a test-file path" do
      r = selector(triggers: ["spec/factories/**"]).select(changed_test: ["spec/factories/players.rb"])
      expect(r.full_run).to be(true)
    end

    it "wins even when source and test changes are also present" do
      r = selector(triggers: ["Gemfile"]).select(
        changed_source: [changed(path, player_src, hunks: [3..3])],
        changed_test: ["spec/player_spec.rb"],
        changed_paths: [path, "spec/player_spec.rb", "Gemfile"]
      )
      expect(r.full_run).to be(true)
      expect(r.example_reasons).to be_empty
      expect(r.test_files).to be_empty
    end

    it "returns empty selection collections on a full run" do
      r = selector(triggers: ["Gemfile"]).select(changed_paths: ["Gemfile"])
      expect(r.uncovered_files).to be_empty
      expect(r.escalations).to be_empty
      expect(r.file_reasons).to be_empty
    end

    it "does not trigger when no path matches" do
      r = selector(triggers: ["Gemfile.lock"]).select(
        changed_source: [changed(path, player_src, hunks: [3..3])]
      )
      expect(r.full_run).to be(false)
    end
  end

  # --- uncovered files ----------------------------------------------------

  describe "uncovered changed files" do
    let(:orphan) { "app/services/new_thing.rb" }
    let(:orphan_src) { "class NewThing\n  def go; end\nend\n" }

    it "flags a changed source file that is absent from the map" do
      r = selector.select(changed_source: [changed(orphan, orphan_src, nil, hunks: [2..2])])
      expect(r.uncovered_files).to eq([orphan])
      expect(r.example_reasons).to be_empty
    end

    it "does not flag a covered file as uncovered" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.uncovered_files).to be_empty
    end

    it "de-duplicates the uncovered list" do
      r = selector.select(changed_source: [changed(orphan, orphan_src, nil, hunks: [1..1, 2..2])])
      expect(r.uncovered_files).to eq([orphan])
    end

    it "does not flag uncovered when a stub back-fills the file" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "instance_double(NewThing)\n")
      r = selector(stub_index: stub)
          .select(changed_source: [changed(orphan, orphan_src, nil, hunks: [2..2])])
      expect(r.uncovered_files).to be_empty
      expect(r.test_files).to include("spec/blind_spec.rb")
    end
  end

  # --- stub back-fill -----------------------------------------------------

  describe "stub back-fill for coverage-blind specs" do
    it "adds a test that stubs a changed method by symbol" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:fn_one)\n")
      r = selector(stub_index: stub).select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.test_files).to include("spec/blind_spec.rb")
    end

    it "adds a test that doubles the changed class" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "instance_double(Player)\n")
      r = selector(stub_index: stub).select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.test_files).to include("spec/blind_spec.rb")
    end

    it "records a stub_match file reason" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:fn_one)\n")
      r = selector(stub_index: stub).select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.file_reasons["spec/blind_spec.rb"].map(&:rule)).to include("stub_match")
    end

    it "back-fills a stub that targets a newly added method" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:fn_three)\n")
      r = selector(stub_index: stub)
          .select(changed_source: [changed(path, player_plus_new, player_src, hunks: [8..8])])
      expect(r.test_files).to include("spec/blind_spec.rb")
    end

    it "adds nothing for a stub that targets an unrelated method" do
      stub = Testalaria::StubIndex.build("spec/blind_spec.rb" => "allow(x).to receive(:unrelated)\n")
      r = selector(stub_index: stub).select(changed_source: [changed(path, player_src, hunks: [3..3])])
      expect(r.test_files).to be_empty
    end
  end

  # --- multiple changed sources & conflicts ------------------------------

  describe "several changed sources at once" do
    let(:team) { "app/models/team.rb" }
    let(:team_src) { "class Team\n  def go; end\nend\n" }

    let(:multi_map) do
      {
        version: 1,
        "e1" => { path => ["Player#fn_one"] },
        "e5" => { path => ["Player#fn_one"], team => ["Team#go"] },
        "e4" => { team => ["Team#go"] }
      }
    end

    it "selects the union of examples across independent files" do
      r = selector(map_data: multi_map).select(changed_source: [
                                       changed(path, player_src, hunks: [3..3]),
                                       changed(team, team_src, hunks: [2..2])
                                     ])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e4", "e5")
    end

    it "unions provenance from two files on a shared example" do
      r = selector(map_data: multi_map).select(changed_source: [
                                       changed(path, player_src, hunks: [3..3]),
                                       changed(team, team_src, hunks: [2..2])
                                     ])
      files = r.example_reasons["e5"].map(&:file)
      expect(files).to include(path, team)
    end

    it "mixes a method_match from one file with an escalation from another" do
      r = selector(map_data: multi_map).select(changed_source: [
                                       changed(path, player_src, hunks: [3..3]),      # method_match
                                       changed(team, team_src, team_src, hunks: [])   # file_change escalation
                                     ])
      expect(r.example_reasons["e1"].map(&:rule)).to eq(["method_match"])
      expect(causes(r)).to include("file_change")
    end

    it "de-duplicates identical reasons when a method is hit by multiple hunks" do
      r = selector.select(changed_source: [changed(path, player_src, hunks: [2..2, 3..3])])
      expect(r.example_reasons["e1"].size).to eq(1)
    end

    it "de-duplicates escalations when several hunks resolve to toplevel" do
      # lines 1 and 4 both resolve to TOPLEVEL -> one toplevel_change escalation.
      r = selector.select(changed_source: [changed(path, player_src, hunks: [1..1, 4..4])])
      expect(r.escalations.count { |e| e.cause == "toplevel_change" }).to eq(1)
    end
  end

  # --- changed constants (reference back-fill) ----------------------------

  describe "a changed constant" do
    # LIMIT (line 2) is read by fn_one (line 4); fn_two never reads it.
    let(:const_src) do
      <<~RUBY
        class Player
          LIMIT = 10
          def fn_one
            LIMIT
          end
          def fn_two
            2
          end
        end
      RUBY
    end

    let(:const_index) { Testalaria::ConstIndex.build(path => const_src) }

    def change_const(hunks)
      selector(const_index: const_index)
        .select(changed_source: [changed(path, const_src, const_src, hunks: hunks)])
    end

    it "selects only the tests that read the constant (const_match)" do
      # LIMIT is read by fn_one -> e1, e3; fn_two's e2 is not selected.
      r = change_const([2..2])
      expect(r.example_reasons.keys).to contain_exactly("e1", "e3")
      expect(r.example_reasons["e1"].map(&:rule)).to include("const_match")
    end

    it "does not escalate toplevel_change for a pure constant change" do
      r = change_const([2..2])
      expect(causes(r)).not_to include("toplevel_change")
    end

    it "records the constant name and reading method on the reason" do
      r = change_const([2..2])
      reason = r.example_reasons["e1"].find { |x| x.rule == "const_match" }
      expect(reason.cause).to eq("LIMIT")
      expect(reason.method).to eq("Player#fn_one")
    end

    it "still escalates toplevel_change for a non-constant class-body change" do
      # line 1 (`class Player`) is toplevel but not a constant assignment.
      r = change_const([1..1])
      expect(causes(r)).to include("toplevel_change")
    end

    it "falls back to a toplevel escalation when no const index is available" do
      r = selector.select(changed_source: [changed(path, const_src, const_src, hunks: [2..2])])
      expect(causes(r)).to include("toplevel_change")
    end
  end

  # --- degenerate input ---------------------------------------------------

  describe "no changes" do
    it "selects nothing and does not trigger a full run" do
      r = selector.select
      expect(r.full_run).to be(false)
      expect(r.example_reasons).to be_empty
      expect(r.test_files).to be_empty
      expect(r.uncovered_files).to be_empty
    end
  end
end
