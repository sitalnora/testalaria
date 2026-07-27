# frozen_string_literal: true

require "testalaria/def_index"
require "testalaria/map"
require "testalaria/map_store"
require "testalaria/selector"
require "testalaria/stub_index"
require "testalaria/runner"
require "testalaria/coverage_digest"

module Testalaria
  # Drives the five-step PR loop of `testalaria:run`:
  #   1. diff vs merge-base; split changed paths into test vs source
  #   2. run changed test files first (fast feedback, needs no map)
  #   3. refresh the map from that run (purge stale keys first)
  #   4. select + run the remainder for changed source files, minus what ran
  #   5. hand the collected data to the report
  #
  # IO (git, subprocess, map file) is injected; the pure decisions
  # (splitting, subtraction, grouping) are extracted as testable methods.
  class Flow
    Outcome = Struct.new(
      :full_run, :trigger, :selection, :suites, :examples_run,
      :map_before, :map_after, :changed_test_files, :changed_source_files,
      :changed_sources, :executed_lines,
      keyword_init: true
    )

    def initialize(config:, git:, runner: Runner.new, store: nil)
      @config = config
      @git = git
      @runner = runner
      @store = store || MapStore.new(path: config.map_path)
      @coverage_path = CoverageDigestStore.path
    end

    def run(target_branch: nil)
      target = target_branch || @config.target_branch
      base = @git.merge_base(target)
      changed = @git.changed_files(base)
      test_files, source_files = split_changed(changed)
      log("target #{target} @ #{base[0, 8]} - #{test_files.size} test, #{source_files.size} source file(s) changed")

      map_before = @store.load
      suites = []
      CoverageDigestStore.new(path: @coverage_path).delete # start diff-coverage clean

      # Step 2-3: purge the changed test files' stale keys, then run them.
      purge_test_files(test_files)
      unless test_files.empty?
        log("running #{test_files.size} changed test file(s) to refresh the map")
        suites.concat(run_test_files(test_files))
      end

      # Reload after the collectors in step 2 wrote fresh entries.
      map = @store.load
      changed_sources = source_files.map { |p| changed_source(base, p) }
      selection = build_selection(map, changed_sources, test_files)

      if selection.full_run
        log("full run triggered by #{selection.trigger}")
        suites.concat(run_full)
      else
        already = already_ran_examples(map, test_files)
        remainder = selection.example_reasons.keys - already.to_a
        extra_files = selection.test_files - test_files
        log("selected #{selection.example_reasons.size} example(s); running #{remainder.size} example(s) + #{extra_files.size} test file(s)")
        suites.concat(run_examples(remainder))
        suites.concat(run_test_files(extra_files))
      end
      log("done - #{suites.size} suite invocation(s)")

      Outcome.new(
        full_run: selection.full_run,
        trigger: selection.trigger,
        selection: selection,
        suites: suites,
        examples_run: (selection.example_reasons.keys + collected_example_keys(test_files)).uniq,
        map_before: map_before,
        map_after: @store.load,
        changed_test_files: test_files,
        changed_source_files: source_files,
        changed_sources: changed_sources,
        executed_lines: CoverageDigestStore.new(path: @coverage_path).load
      )
    end

    # Aggregate exit status: non-zero if any invoked suite failed.
    def self.exit_status(outcome)
      outcome.suites.any? { |s| s.exit_status != 0 } ? 1 : 0
    end

    # --- pure-ish helpers (unit tested) -------------------------------------

    def split_changed(paths)
      paths.partition { |p| @config.test_file?(p) }
    end

    # Example keys in the map that belong to a given changed test file — RSpec
    # ids by "./path" prefix, Minitest ids by the class names defined in it.
    def keys_for_test_file(map, path)
      prefixes = ["./#{path}", path]
      classes = test_file_classes(path)
      Map.example_keys(map).select do |key|
        k = key.to_s
        prefixes.any? { |pre| k.start_with?("#{pre}[") } ||
          classes.any? { |c| k.start_with?("#{c}#") }
      end
    end

    def already_ran_examples(map, test_files)
      test_files.flat_map { |tf| keys_for_test_file(map, tf) }.uniq
    end

    # Group runnable example ids by framework and dispatch to the right runner.
    def group_examples_by_runner(example_ids)
      groups = Hash.new { |h, k| h[k] = [] }
      example_ids.each { |id| groups[framework_of(id)] << id }
      groups
    end

    def framework_of(example_id)
      example_id.include?("[") ? "rspec" : "minitest"
    end

    private

    # Opt-in progress, to stderr so it never pollutes the report on stdout.
    def log(message)
      warn "testalaria: #{message}" if ENV["TESTALARIA_PROGRESS"] == "1"
    end

    def build_selection(map, changed_sources, test_files)
      log("analyzing #{Map.example_keys(map).size} mapped example(s) + indexing stubs across test files...")
      stub_index = build_stub_index
      const_index = build_const_index(changed_constants(changed_sources))
      selector = Selector.new(
        map: map, full_run_triggers: @config.full_run_triggers,
        stub_index: stub_index, const_index: const_index
      )
      selector.select(
        changed_source: changed_sources,
        changed_test: test_files,
        changed_paths: changed_sources.map(&:path) + test_files
      )
    end

    # Bare names of constants whose assignment lines were touched by the diff.
    def changed_constants(changed_sources)
      changed_sources.flat_map do |cs|
        next [] unless cs.head_index

        lines = Array(cs.hunks).flat_map(&:to_a)
        cs.head_index.const_entries
          .select { |e| lines.any? { |l| e.range.cover?(l) } }
          .map(&:name)
      end.uniq
    end

    # Build a const reference index only when a constant actually changed - and
    # only over source files that textually mention one of the changed names, so
    # we don't parse the whole tree on every run.
    def build_const_index(changed_consts)
      return nil if changed_consts.empty?

      log("constant(s) changed (#{changed_consts.join(', ')}); indexing references")
      sources = {}
      Dir.glob("**/*.rb").each do |file|
        next if @config.test_file?(file) || file.include?("/vendor/") || !File.exist?(file)

        src = File.read(file)
        sources[file] = src if changed_consts.any? { |c| src.include?(c) }
      end
      ConstIndex.build(sources)
    end

    def changed_source(base, path)
      head_src = File.exist?(path) ? File.read(path) : nil
      base_src = @git.file_at(base, path)
      Selector::ChangedSource.new(
        path: path,
        hunks: @git.hunks(base, path),
        head_index: head_src && safe_index(head_src),
        base_index: base_src && safe_index(base_src)
      )
    end

    def safe_index(source)
      DefIndex.build(source)
    rescue ParseError
      nil
    end

    def build_stub_index
      sources = {}
      @config.runners.each do |runner|
        Dir.glob(runner.pattern).each { |f| sources[f] = File.read(f) if File.exist?(f) }
      end
      StubIndex.build(sources)
    end

    def purge_test_files(test_files)
      return if test_files.empty?

      map = @store.load
      test_files.each do |tf|
        keys_for_test_file(map, tf).each { |k| map.delete(k) }
      end
      @store.dump(map)
    end

    def run_test_files(files)
      files.group_by { |f| @config.runner_for(f) }.filter_map do |runner_config, group|
        next unless runner_config

        @runner.run_files(runner_config, group, env: subprocess_env)
      end
    end

    def run_examples(example_ids)
      group_examples_by_runner(example_ids).filter_map do |framework, ids|
        runner_config = @config.runners.find { |r| r.name == framework }
        next unless runner_config

        locator = framework == "minitest" ? minitest_locator : nil
        @runner.run_examples(runner_config, ids, locator: locator, env: subprocess_env)
      end
    end

    def run_full
      @config.runners.map { |runner_config| @runner.run_files(runner_config, [], env: subprocess_env) }
    end

    # Env handed to every collecting subprocess so it writes the map and the
    # coverage digest exactly where the orchestration reads them back.
    def subprocess_env
      { "TESTALARIA_MAP" => @config.map_path, "TESTALARIA_COVERAGE" => @coverage_path }
    end

    def minitest_locator
      mt = @config.runners.find { |r| r.name == "minitest" }
      mt ? TestLocator.from_glob([mt.pattern]) : TestLocator.new
    end

    def collected_example_keys(test_files)
      map = @store.load
      test_files.flat_map { |tf| keys_for_test_file(map, tf) }
    end

    def test_file_classes(path)
      return [] unless File.exist?(path)

      DefIndex.build(File.read(path)).entries.map { |e| e.name.split(/[#.]/).first }.uniq
    rescue ParseError
      []
    end
  end
end
