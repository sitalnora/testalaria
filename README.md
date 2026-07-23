# testalaria

Regression test selection for Ruby (≥ 2.7), framework-agnostic across RSpec and
Minitest. Run only the tests a change could plausibly break, instead of the whole
suite.

A test can only fail because of code it actually executed. Testalaria records, per
test, which methods it executed into a committed map (`.testalaria.yml`); "which
tests can my change break?" then becomes a diff-plus-lookup.

## Status

Phases 0–4 implemented (collection, selection, orchestration, report). See the
design docs at the repo root for the full reference:

- `test_selection_design.md` — how it works, full reference detail.
- `test_selection_plan.md` — v0.1 scope, phases, artifact schema.
- `test_selection_testing.md` — test strategy (seams, layers, scenarios).

## Usage

Load the tasks from your project's `Rakefile`:

```ruby
require "testalaria/rake_tasks"
```

One-time setup — record your suite commands and seed the map:

```
rake testalaria:setup RSPEC_CMD="bundle exec rspec" MINITEST_CMD="bundle exec rails test"
```

This writes `.testalaria.config.yml` (committed), appends `.testalaria.yml` to
`.dockerignore`, and does one full run per runner under `TESTALARIA=1` to build the
initial map.

### Activating collection

The map is built *inside* your suite process, so the collector must be loaded there.

- **Minitest:** nothing to do — the bundled plugin (`minitest/testalaria_plugin.rb`)
  is auto-discovered and activates only under `TESTALARIA=1`.
- **RSpec:** add one line to your `.rspec` (no auto-discovery mechanism exists):

  ```
  --require testalaria/rspec
  ```

  It's a no-op unless `TESTALARIA=1`, so it's safe to leave in permanently.

`setup` prints this RSpec reminder. If the collector isn't loaded, the seed run
records an empty map.

Every PR run (drop into CI as a single step):

```
rake testalaria:run     # diff vs merge-base, run changed tests, select+run the rest,
                        # refresh the map, write .testalaria.report.yml, exit non-zero on failure
VERBOSE=1 rake testalaria:run   # also print the selection trace
TARGET_BRANCH=origin/release-x rake testalaria:run   # override the diff target
rake testalaria:lint    # repo-wide nondeterminism scan
```

## Artifact schema (v1)

`testalaria:run` writes `.testalaria.report.yml`:

```yaml
version: 1
map_commit: <sha>
head: <sha>
selection:
  total_known_examples: 9300
  examples_selected: 412
  full_run_triggered: false
  trigger: null
tested:
  app/models/player.rb:
    - "./spec/player_spec.rb[1:1]"
affected:
  uncovered_changed_files: ["app/services/new_thing.rb"]
  co_executed_neighbors: ["app/models/team.rb"]
  escalations:
    - { file: app/models/player.rb, reason: new_method }
untested_new_code:
  - { file: app/models/player.rb, method: "Player#apply_bonus" }
nondeterminism:
  - { file: app/models/shipping.rb, line: 4, pattern: "Time.now", severity: warn, exposed_examples: 7 }
selection_trace:
  "./spec/player_spec.rb[1:1]":
    - { rule: method_match, file: app/models/player.rb, method: "Player#fn_one" }
```

## Architecture

Everything the gem does is one of two lifecycles — **RECORD** (watch tests run,
remember what each executed) and **SELECT** (given a diff, look up which tests to
run) — plus glue. The **map** (`.testalaria.yml`, committed) is the shared artifact:
RECORD writes it, SELECT reads it.

```
        RECORD (during a test run, TESTALARIA=1)          SELECT (rake testalaria:run)
        ─────────────────────────────────────────         ──────────────────────────────
  test suite ──> adapter ──> session ──> collector          git diff ──> selector ──> runner
                                │            │                   │           │            │
                                │       (coverage→methods)       │      (map lookup)      │
                                ▼            ▼                    ▼           ▼            ▼
                          .testalaria.yml  (the MAP)  <──────────┘      picks examples   shells out
                          .testalaria.coverage.yml (digest)                               to rspec/minitest
```

### Data flow — RECORDING (`TESTALARIA=1`)

```
   RSpec / Minitest test suite
            │  before(:each) / after(:each)
            ▼
   adapters/rspec.rb ─┐
   adapters/minitest.rb ─┴─> session.rb        "example './spec/x[1:1]' starting / done"
            │
            ▼
   collector.rb   ── asks ──> coverage_source.rb  (wraps Ruby's Coverage; snapshot before+after)
            │                        │
            │   lines that moved ────┘
            ▼
   resolver.rb  ── uses ──> def_index.rb   (Ripper parse: "line 3 lives in Player#fn_one")
            │
            │  { example => { file => [methods] } }
            ▼
   session.flush ──> map.rb ──> map_store.rb ──────────> .testalaria.yml   (the MAP)
                 └─> coverage_digest.rb ──────────────> .testalaria.coverage.yml (executed lines)
```

### Data flow — SELECTING (`rake testalaria:run`)

```
   rake_tasks.rb ──> cli.rb ──> flow.rb  (conductor of the 5-step loop)
                                   │
        step 1  ── git.rb ────────┤  diff vs merge-base → changed files (test vs source)
        step 2  ── runner.rb ─────┤  run changed TEST files first  ─────────┐
        step 3  ── map_store ─────┤  reload the map they just refreshed      │  (subprocesses,
        step 4  ── selector.rb ───┤  which examples? ↓                       │   TESTALARIA=1,
                     ├─ def_index.rb / resolver.rb  (changed lines→methods)  │   feed the RECORD
                     ├─ stub_index.rb  (tests that mock the changed method)  │   flow above)
                     └─ config.rb full_run_triggers                          │
                   runner.rb ─────┤  run the SELECTED source examples ───────┘
        step 5  ── report.rb ─────┘  → terminal + .testalaria.report.yml
                     └─ rot_lint.rb (nondeterminism scan)
```

### What each file does

**Entry points — how you invoke it**

| File | Job |
|---|---|
| `rake_tasks.rb` | Defines `testalaria:setup / :run / :lint`. What a host project requires. |
| `cli.rb` | Behind the tasks: wires real objects, prints report, writes artifact, returns exit code. |
| `setup.rb` | `:setup` — writes `.testalaria.config.yml`, seeds the first full map, touches `.dockerignore`. |
| `config.rb` | Loads/validates that config file (commands, patterns, target branch, triggers). |

**RECORD side — turn a running test into map entries**

| File | Job |
|---|---|
| `adapters/rspec.rb` | Hooks `before/after(:each)`; example id = `./spec/x[1:2]`. |
| `adapters/minitest.rb` | Prepends `before_setup/after_teardown`; id = `Class#test_x`. |
| `session.rb` | Per-process recorder: accumulates entries, flushes map + digest at suite end. |
| `coverage_source.rb` | Wraps Ruby's `Coverage` (piggyback or start; oneshot guard; shape normalize). |
| `collector.rb` | Before/after diff → moved lines → (via resolver) `{file => methods}`; also `executed_lines`. |

**The shared brain — parse Ruby, resolve lines↔methods (used by BOTH sides)**

| File | Job |
|---|---|
| `def_index.rb` | Ripper walker: source → `"Player#fn_one" => 2..3` table + `(toplevel)` + dynamic flag. |
| `resolver.rb` | Given that table: "line 3 → Player#fn_one". The one place lines become names. |

**The map — the memory**

| File | Job |
|---|---|
| `map.rb` | Pure in-memory map: deterministic YAML dump, merge, prune. |
| `map_store.rb` | Reads/writes `.testalaria.yml` atomically. |
| `coverage_digest.rb` | Sidecar of executed *lines* (for diff-coverage); the map only keeps method names. |

**SELECT side — diff → which tests**

| File | Job |
|---|---|
| `git.rb` | merge-base, changed files, hunks, `git show sha:file`. |
| `selector.rb` | The heart: changed methods → examples, with the escalation ladder + provenance. |
| `stub_index.rb` | Scans test files for `receive(:x)`/`instance_double(Const)` → adds mock-blind tests back. |
| `runner.rb` | Shells out to configured commands; formats RSpec ids / Minitest `-n` filters. |
| `flow.rb` | Orchestrates the 5-step loop; produces the `Outcome`. |

**OUTPUT side**

| File | Job |
|---|---|
| `report.rb` | `Outcome` → 4-section report (tested / affected / untested-new-code / trace) + artifact. |
| `rot_lint.rb` | Static scan for `Time.now`/`rand`/`ENV`/flags; joined against the map. |

**Root / packaging**

| File | Job |
|---|---|
| `testalaria.rb` | Requires everything, defines the error classes. |
| `version.rb` | `VERSION`. |

**Files it produces**

| File | Committed? | Purpose |
|---|---|---|
| `.testalaria.yml` | yes | the map — travels with the code |
| `.testalaria.config.yml` | yes | suite commands, target branch, triggers |
| `.testalaria.report.yml` | no | per-run analysis report |
| `.testalaria.coverage.yml` | no | ephemeral executed-lines digest for diff-coverage |

The one mental model that unlocks it all: **`def_index` + `resolver` are used
identically on both sides** — recording resolves *Coverage's* lines to write the
map; selecting resolves *git's* lines to read it. Same parser, so the writer and
reader can never disagree about which method a line belongs to.

## Development

```
bundle install
bundle exec rake        # runs the gem's own L1-L4 test suite
```

The gem's tests live under `spec/`; two fixture apps under `spec/fixtures/`
(`rspec_app`, `minitest_app`) exercise the adapters end-to-end.
