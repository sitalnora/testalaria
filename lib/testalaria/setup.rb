# frozen_string_literal: true

require "psych"
require "testalaria/config"
require "testalaria/map_store"
require "testalaria/runner"
require "testalaria/git"

module Testalaria
  # Implements `rake testalaria:setup`: persist the suite commands the project
  # uses (the one thing the gem can't infer) to a committed config file, append
  # the map path to .dockerignore, then seed the map with one full run per
  # runner under TESTALARIA=1.
  module Setup
    DEFAULT_PATTERNS = {
      "rspec" => "spec/**/*_spec.rb",
      "minitest" => "test/**/*_test.rb"
    }.freeze

    DEFAULT_TRIGGERS = %w[Gemfile Gemfile.lock].freeze

    module_function

    # @param commands [Hash] "rspec"/"minitest" => command string
    def run(commands:, config_path: Config::DEFAULT_PATH,
            map_path: MapStore::DEFAULT_PATH, process: Runner::ProcessRunner.new,
            git: Git.new, out: $stdout)
      runners = build_runners(commands)
      raise ConfigError, "pass at least one of RSPEC_CMD / MINITEST_CMD" if runners.empty?

      write_config(config_path, map_path, runners)
      append_dockerignore(map_path)
      seed(runners, process, git, out, map_path)
      out.puts "testalaria: wrote #{config_path} and seeded #{map_path}"
      print_activation_hint(runners, out)
    end

    # Already in the final config shape: { name => { "command", "pattern" } }.
    def build_runners(commands)
      commands.each_with_object({}) do |(name, command), acc|
        next if command.nil? || command.empty?

        acc[name] = {
          "command" => command,
          "pattern" => DEFAULT_PATTERNS.fetch(name, "spec/**/*_spec.rb")
        }
      end
    end

    def write_config(config_path, map_path, runners)
      config = {
        "map_path" => map_path,
        "target_branch" => "origin/main",
        "runners" => runners,
        "simplecov" => "auto",
        "full_run_triggers" => DEFAULT_TRIGGERS
      }
      File.write(config_path, Psych.dump(config))
    end

    def append_dockerignore(map_path, path: ".dockerignore")
      existing = File.exist?(path) ? File.read(path) : ""
      return if existing.split("\n").include?(map_path)

      File.write(path, "#{existing}#{existing.empty? ? '' : "\n"}#{map_path}\n")
    end

    def seed(runners, process, git, out, map_path)
      sha = current_sha(git)
      # Point the collecting subprocess at the *configured* map path, so it
      # writes where the everyday run will later read.
      env = { "TESTALARIA" => "1", "TESTALARIA_MAP" => map_path }
      env["TESTALARIA_COMMIT"] = sha if sha
      runners.each_value do |spec|
        out.puts "testalaria: seeding via `#{spec['command']}`"
        process.run(spec["command"], env: env)
      end
    end

    # RSpec has no plugin auto-discovery, so the project must load the adapter
    # itself. Minitest is picked up automatically via the bundled plugin.
    def print_activation_hint(runners, out)
      return unless runners.key?("rspec")

      out.puts "testalaria: add `--require testalaria/rspec` to your .rspec " \
               "so collection activates under TESTALARIA=1"
    end

    # The map is built against the working tree (HEAD), so :commit is stamped
    # with HEAD's sha — freshness metadata, "which commit these entries reflect".
    # This is deliberately not the merge-base with the target branch: that base
    # is only the diff anchor for selection (see Flow), not what the map records.
    def current_sha(git)
      git.head_sha
    rescue StandardError
      nil
    end
  end
end
