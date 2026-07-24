# testalaria

<p align="center">
  <img width="500" height="300" alt="image" src="https://github.com/user-attachments/assets/3fa5a82f-ddbf-427c-8391-b51566a68671" />
</p>


Regression test selection for Ruby (≥ 2.7), framework-agnostic across **RSpec** and
**Minitest**. Run only the tests a change could plausibly break, instead of the whole
suite.

The premise: *a test can only fail because of code it actually executed.* testalaria
records, per test, which methods it ran into a committed map (`.testalaria.yml`).
"Which tests can my change break?" then becomes a diff-plus-lookup.

---

## Requirements

- Ruby ≥ 2.7
- RSpec and/or Minitest
- A git repository (selection diffs against a branch)

## Install

In your app's `Gemfile`:

```ruby
group :development, :test do
  gem "testalaria"
  # or, for a local checkout:
  # gem "testalaria", path: "../testalaria"
end
```

```bash
bundle install
```

Load the rake tasks from your `Rakefile`:

```ruby
require "testalaria/rake_tasks"
```

Check they registered:

```bash
bundle exec rake -T | grep testalaria
# testalaria:setup   Generate .testalaria.config.yml and seed the map
# testalaria:run     Select and run the tests a PR's changes could break
# testalaria:lint    Repo-wide nondeterminism scan
```

---

## Setup (one time)

Record your suite command(s) and build the initial map. Pass at least one of
`RSPEC_CMD` / `MINITEST_CMD`:

```bash
# RSpec
bundle exec rake testalaria:setup RSPEC_CMD="bundle exec rspec"

# Minitest (Rails)
bundle exec rake testalaria:setup MINITEST_CMD="bin/rails test"

# both
bundle exec rake testalaria:setup RSPEC_CMD="bundle exec rspec" MINITEST_CMD="bin/rails test"
```

This:

1. writes `.testalaria.config.yml` (commit it),
2. appends `.testalaria.yml` to `.dockerignore`,
3. runs your **whole suite once** under `TESTALARIA=1` to seed the map — so it takes
   roughly your normal suite time × ~1.5–2 (coverage overhead).

### Activating collection in your suite

The map is built *inside* your test process, so the collector must load there:

- **Minitest** — nothing to do. The bundled plugin (`minitest/testalaria_plugin.rb`)
  is auto-discovered and is a no-op unless `TESTALARIA=1`.
- **RSpec** — add one line to your `.rspec` (there's no auto-discovery hook):

  ```
  --require testalaria/rspec
  ```

  It's a no-op unless `TESTALARIA=1`, so it's safe to leave in permanently. **If you
  skip this, the seed records an empty map.**

### Minitest command requirements

The runner appends targets to your command as `<file> -n "/regex/"`. This works with
`bin/rails test`. Plain `Rake::TestTask` (`rake test`) does **not** accept file/`-n`
arguments on the command line — wrap it, or use `bin/rails test`.

### Parallel test suites

If your suite forks workers (e.g. Rails `parallelize`), they race on the single map
file during the seed and can produce an incomplete map. For a clean seed, force one
process:

```bash
PARALLEL_WORKERS=1 bundle exec rake testalaria:setup MINITEST_CMD="bin/rails test"
```

---

## Everyday use

Run this as a single CI step on a PR branch:

```bash
bundle exec rake testalaria:run
```

It diffs against the merge-base with your target branch, runs the changed test files
first (refreshing the map), selects and runs the tests the source changes could break,
writes `.testalaria.report.yml`, and exits non-zero if any suite failed.

Repo-wide nondeterminism scan (informational, never fails the build):

```bash
bundle exec rake testalaria:lint
```

---

## Flags & environment variables

### `testalaria:setup`

| Var | Purpose |
|---|---|
| `RSPEC_CMD` | Command to run your RSpec suite (e.g. `bundle exec rspec`). |
| `MINITEST_CMD` | Command to run your Minitest suite (e.g. `bin/rails test`). |

### `testalaria:run`

| Var | Effect |
|---|---|
| `TARGET_BRANCH` | Override the diff target (default: config `target_branch`, usually `origin/main`). |
| `TESTALARIA_PROGRESS=1` | Print a line per phase **and** stream the suite's live output (otherwise quiet + captured). |
| `VERBOSE=1` / `VERBOSE_SMALL=1` | Append the selection trace: `test <- rule`. |
| `VERBOSE_BIG=1` | Append the detailed trace: `test <- rule (file method)` — shows which changed method selected each test. |

```bash
VERBOSE_BIG=1 TESTALARIA_PROGRESS=1 TARGET_BRANCH=master bundle exec rake testalaria:run
```

### Advanced / internal

Set automatically for the collecting subprocesses; override only for reproducible maps
or custom layouts.

| Var | Purpose |
|---|---|
| `TESTALARIA=1` | Activates collection inside the suite process. |
| `TESTALARIA_MAP` | Map file path (default `.testalaria.yml`). |
| `TESTALARIA_COVERAGE` | Coverage-digest path (default `.testalaria.coverage.yml`). |
| `TESTALARIA_COMMIT` | Pin the map's `:commit` metadata (goldens / reproducible builds). |
| `TESTALARIA_TIMESTAMP` | Pin the map's `:timestamp` metadata. |

---

## Configuration — `.testalaria.config.yml`

Written by `setup`; commit it. Full shape with defaults:

```yaml
map_path: .testalaria.yml          # where the committed map lives
target_branch: origin/main         # diff target for selection
runners:
  rspec:
    command: "bundle exec rspec"
    pattern: "spec/**/*_spec.rb"    # which paths count as this runner's test files
  minitest:
    command: "bin/rails test"
    pattern: "test/**/*_test.rb"
simplecov: auto                     # coexist with an existing SimpleCov Coverage session
full_run_triggers:                  # any changed path matching these forces a full run
  - Gemfile
  - Gemfile.lock
```

`full_run_triggers` are matched with `File.fnmatch` (glob). A change to a dependency or
global config can affect anything coverage can't attribute, so it's a deliberate
"run everything" escalation.

---

## Files it creates

| File | Committed? | Purpose |
|---|---|---|
| `.testalaria.yml` | **yes** | the map — travels with the code |
| `.testalaria.config.yml` | **yes** | suite commands, target branch, triggers |
| `.testalaria.report.yml` | no | per-run analysis report |
| `.testalaria.coverage.yml` | no | ephemeral executed-lines digest (diff coverage) |

The map is rewritten (deterministically) on every run, so a normal PR only diffs the
slice of examples whose tests changed. For a large map, mark it generated so reviews
stay clean:

```
# .gitattributes
.testalaria.yml linguist-generated=true
```

On merge conflicts in the map, take either side and let the next `testalaria:run`
refresh it — it's regenerable. (Do **not** use a `merge=union` driver: it corrupts the
YAML.)

---

## How selection works

1. **Diff** vs the merge-base; split changed paths into test files vs source files.
2. **Full-run trigger?** If any changed path matches `full_run_triggers`, run everything.
3. **Changed test files** run first (and refresh their own map entries).
4. **Changed source** is resolved to methods and looked up in the map:
   - **method-level** by default — only tests that executed the changed method run
     (`method_match`);
   - **escalates to file-level** when a change can't be pinned to a method:
     `new_method`, `toplevel_change` (class body), `dynamic_def` (metaprogramming),
     `rename`, `file_change` (no hunk detail), `file_deleted`;
   - **stub back-fill** — tests that mock the changed method/class are added, since
     coverage can't see through stubs;
   - **uncovered** — a changed source file with no map entry is surfaced as exposed.
5. **Report** — every selection carries provenance (why it was chosen).

Dynamic/metaprogrammed files (`define_method`, `class_eval`, …) resolve at file level,
because their methods aren't statically nameable.

---

## The report

`testalaria:run` prints a summary and writes `.testalaria.report.yml`:

```yaml
version: 1
map_commit: <sha>
head: <sha>
selection:
  total_known_examples: 5982
  examples_selected: 42
  full_run_triggered: false
  trigger: null
tested:                              # changed source file => tests it selected
  app/models/member.rb:
    - "MemberTest#test_status"
affected:
  uncovered_changed_files: []
  co_executed_neighbors: []
  escalations: []
untested_new_code:                   # added code no test exercised
  - { file: app/models/member.rb, method: "Member#new_thing" }
nondeterminism:
  - { file: app/models/x.rb, line: 4, pattern: "Time.now", severity: warn, exposed_examples: 7 }
selection_trace:                     # per example: why it was selected
  "MemberTest#test_status":
    - { rule: method_match, file: app/models/member.rb, method: "Member#status" }
```

`VERBOSE_SMALL` / `VERBOSE_BIG` append the trace to the terminal too.

---

## Troubleshooting

- **`GitError: ... merge-base origin/main HEAD failed`** — your target branch ref
  doesn't resolve. Use `TARGET_BRANCH=master` (or `origin/master`), or `git fetch`
  the ref, or fix `target_branch` in the config.
- **Everything runs / "full run triggered by Gemfile"** — a changed path matched a
  `full_run_trigger`. Note that *installing testalaria edits your Gemfile*, so early
  runs trigger a full run until the setup commit is in your base branch.
- **`coverage measurement is not enabled` / digest skipped** — SimpleCov collected and
  stopped Coverage before the suite-end flush (common on Ruby < 3.1, where
  `Coverage.running?` doesn't exist). The map is unaffected; only the line-level
  diff-coverage (`untested_new_code` precise lines) degrades to a method-level
  approximation.
- **`Encoding::UndefinedConversionError (U+2014 ...)`** when post-processing the map —
  your locale is US-ASCII. Run with `LANG=en_US.UTF-8` or read files with
  `encoding: "UTF-8"`.
- **Only one Minitest test ran / `command not found`** — you're on an old build; the
  runner now shell-escapes targets and combines Minitest filters into one `-n`.

---

## Architecture

Two lifecycles share the map:

- **RECORD** (during a test run, `TESTALARIA=1`): adapter → session → collector turns
  each example's coverage into `{ file => [methods] }` and flushes `.testalaria.yml`.
- **SELECT** (`testalaria:run`): git diff → selector looks up the map → runner shells
  out to your configured commands.

`def_index` + `resolver` (a Ripper parse mapping lines ↔ method names) are used
identically on both sides, so the writer and reader can never disagree about which
method a line belongs to. See the design docs at the repo root for full detail.

## Development

```bash
bundle install
bundle exec rake        # the gem's own L1–L4 test suite
```

Fixture apps under `spec/fixtures/` (`rspec_app`, `minitest_app`) exercise the adapters
end to end.
