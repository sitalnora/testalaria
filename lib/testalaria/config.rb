# frozen_string_literal: true

require "psych"

module Testalaria
  # Loads and validates `.testalaria.config.yml` — the small, committed file
  # that records the one thing the gem can't infer (the commands the project
  # uses to run its suites) plus the diff target and full-run triggers.
  class Config
    DEFAULT_PATH = ".testalaria.config.yml"

    Runner = Struct.new(:name, :command, :pattern, keyword_init: true)

    attr_reader :map_path, :target_branch, :runners, :full_run_triggers, :simplecov

    def self.load(path = DEFAULT_PATH)
      raise ConfigError, "config not found at #{path}; run `rake testalaria:setup`" unless File.exist?(path)

      yaml = File.read(path)
      data = Psych.respond_to?(:unsafe_load) ? Psych.unsafe_load(yaml) : Psych.load(yaml)
      raise ConfigError, "invalid config at #{path}" unless data.is_a?(Hash)

      new(data)
    end

    def initialize(data)
      @map_path = data["map_path"] || MapStore::DEFAULT_PATH
      @target_branch = data["target_branch"] || "origin/main"
      @runners = build_runners(data["runners"] || {})
      @full_run_triggers = data["full_run_triggers"] || []
      @simplecov = data.fetch("simplecov", "auto")
      raise ConfigError, "config defines no runners" if @runners.empty?
    end

    # The runner whose pattern matches a given test-file path, or nil.
    def runner_for(path)
      @runners.find { |r| File.fnmatch?(r.pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
    end

    # True if the path looks like a test file for any runner.
    def test_file?(path)
      !runner_for(path).nil?
    end

    private

    def build_runners(hash)
      hash.map do |name, cfg|
        Runner.new(name: name.to_s, command: cfg["command"], pattern: cfg["pattern"])
      end
    end
  end
end
