# frozen_string_literal: true

require "testalaria/config"
require "testalaria/git"
require "testalaria/flow"
require "testalaria/report"
require "testalaria/rot_lint"

module Testalaria
  # Thin entry layer behind the rake tasks: wires the real implementations
  # together, prints the report, writes the machine-readable artifact, and
  # returns the aggregate exit status.
  module CLI
    ARTIFACT_PATH = ".testalaria.report.yml"

    module_function

    # Implements `testalaria:run`. Returns the process exit status.
    def run(config_path: Config::DEFAULT_PATH, out: $stdout, artifact_path: ARTIFACT_PATH)
      config = Config.load(config_path)
      git = Git.new
      outcome = Flow.new(config: config, git: git).run(target_branch: ENV["TARGET_BRANCH"])

      report = Report.new(outcome, head: head_sha(git))
      File.write(artifact_path, report.artifact_yaml)
      verbose, trace = trace_mode
      out.puts report.terminal(verbose: verbose, trace: trace)

      Flow.exit_status(outcome)
    end

    # VERBOSE_BIG -> full "rule (file method)" chain; VERBOSE / VERBOSE_SMALL ->
    # just "rule". Returns [verbose?, level].
    def trace_mode
      return [true, :big] if ENV["VERBOSE_BIG"] == "1"
      return [true, :small] if ENV["VERBOSE"] == "1" || ENV["VERBOSE_SMALL"] == "1"

      [false, :small]
    end

    # Implements `testalaria:lint` — repo-wide nondeterminism scan.
    def lint(config_path: Config::DEFAULT_PATH, out: $stdout)
      config = Config.load(config_path)
      map = MapStore.new(path: config.map_path).load
      findings = scan_repo(config, map)
      findings.each do |f|
        out.puts "#{f.severity.upcase} #{f.file}:#{f.line} #{f.pattern} " \
                 "(#{RotLint.exposure(f.file, map)} exposed)"
      end
      out.puts "testalaria: #{findings.size} nondeterminism finding(s)"
      findings.empty? ? 0 : 0 # informational; never fails the build
    end

    def scan_repo(config, _map)
      source_glob = Dir.glob("**/*.rb").reject { |p| config.test_file?(p) }
      source_glob.flat_map do |file|
        RotLint.scan(File.read(file), file: file)
      rescue StandardError
        []
      end
    end

    def head_sha(git)
      git.head_sha
    rescue StandardError
      nil
    end
  end
end
