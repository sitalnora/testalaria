# frozen_string_literal: true

require "rake"
require "testalaria"
require "testalaria/setup"
require "testalaria/cli"

# Two tasks mirroring the two lifecycles: one-time configuration + map seeding,
# and the everyday zero-argument run. Load this from a project's Rakefile with
# `require "testalaria/rake_tasks"`.
namespace :testalaria do
  desc "Generate .testalaria.config.yml and seed the map (RSPEC_CMD=... MINITEST_CMD=...)"
  task :setup do
    commands = {
      "rspec" => ENV["RSPEC_CMD"],
      "minitest" => ENV["MINITEST_CMD"]
    }
    Testalaria::Setup.run(commands: commands)
  end

  desc "Select and run the tests a PR's changes could break; emit the report"
  task :run do
    exit(Testalaria::CLI.run)
  end

  desc "Print the selected test targets (one per line; 'ALL' = full run) without running them, for sharding"
  task :list do
    exit(Testalaria::CLI.list)
  end

  desc "Repo-wide nondeterminism scan"
  task :lint do
    exit(Testalaria::CLI.lint)
  end
end
