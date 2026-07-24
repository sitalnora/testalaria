# frozen_string_literal: true

require "open3"
require "shellwords"
require "testalaria/def_index"

module Testalaria
  # Shells out to the *configured* suite commands rather than embedding a
  # runner, so anything the team already wraps around their tests (Spring,
  # RAILS_ENV, parallel wrappers, binstubs) keeps working — we only append
  # targets and set the TESTALARIA=1 env flag.
  class Runner
    Result = Struct.new(:exit_status, :stdout, keyword_init: true)

    # The default process seam (Open3). Swapped for FakeRunner in tests.
    class ProcessRunner
      def run(cmd, env: {})
        # With TESTALARIA_PROGRESS=1, stream the suite's own output live so you
        # can watch it run; otherwise capture it (quiet — the default).
        if ENV["TESTALARIA_PROGRESS"] == "1"
          ok = system(env, cmd)
          Result.new(exit_status: ok ? 0 : 1, stdout: "")
        else
          stdout, status = Open3.capture2(env, cmd)
          Result.new(exit_status: status.exitstatus, stdout: stdout)
        end
      end
    end

    def initialize(process: ProcessRunner.new, base_env: { "TESTALARIA" => "1" })
      @process = process
      @base_env = base_env
    end

    # Run whole test files (flow step 2 / full-file reruns). Returns a Result.
    def run_files(runner_config, files, env: {})
      invoke(runner_config.command, files, env)
    end

    # Run a set of selected examples for one runner (flow step 4).
    #   * RSpec: native ids are passed directly as targets.
    #   * Minitest: grouped by file, filtered with -n "/(a|b)/".
    def run_examples(runner_config, example_ids, locator: nil, env: {})
      targets =
        if rspec?(runner_config)
          example_ids
        else
          minitest_targets(example_ids, locator)
        end
      invoke(runner_config.command, targets, env)
    end

    # Formats Minitest example ids ("Class#test") into `file -n "/(t1|t2)/"`
    # target fragments using a class->file locator.
    def minitest_targets(example_ids, locator)
      by_file = Hash.new { |h, k| h[k] = [] }
      example_ids.each do |id|
        klass, test = id.split("#", 2)
        file = locator&.file_for(klass)
        next unless file && test

        by_file[file] << test
      end
      return [] if by_file.empty?

      # Minitest/Rails honor only the LAST -n, so a -n per file would silently
      # drop every file but one. Pass all target files and ONE combined filter:
      # every file loads and the union of names runs (cross-file name collisions
      # merely over-select, which is safe) — in a single boot.
      names = by_file.values.flatten.map { |t| Regexp.escape(t) }
      [*by_file.keys, "-n", "/#{names.join('|')}/"]
    end

    private

    def invoke(command, targets, env)
      # The command is a raw shell string (may carry env prefixes / binstubs),
      # so it runs through a shell. Targets, though, can contain shell
      # metacharacters — RSpec ids have `[1:1]` (globs), Minitest filters are
      # `-n /a|b/` (pipes + slashes) — so each is shell-escaped to reach the
      # runner intact instead of being split into a bogus pipeline.
      args = targets.reject { |t| t.nil? || t.empty? }.map { |t| Shellwords.escape(t) }
      cmd = [command, *args].join(" ")
      @process.run(cmd, env: @base_env.merge(env))
    end

    def rspec?(runner_config)
      runner_config.name == "rspec"
    end
  end

  # Maps Minitest class names to their defining test file by parsing the
  # configured test files with the shared DefIndex machinery.
  class TestLocator
    def self.from_glob(patterns)
      map = {}
      Array(patterns).each do |pattern|
        Dir.glob(pattern).each do |file|
          index_classes(file, map)
        end
      end
      new(map)
    end

    def self.index_classes(file, map)
      DefIndex.build(File.read(file)).entries.each do |entry|
        klass = entry.name.split(/[#.]/).first
        map[klass] ||= file unless klass.nil? || klass.empty?
      end
    rescue ParseError, Errno::ENOENT
      # skip unparseable/vanished test files
    end

    def initialize(map = {})
      @map = map
    end

    def file_for(class_name)
      @map[class_name]
    end
  end
end
