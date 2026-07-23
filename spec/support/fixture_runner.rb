# frozen_string_literal: true

require "bundler"

# Runs a fixture app's suite as a subprocess under TESTALARIA=1, with the gem's
# lib injected on the load path and the map's freshness metadata pinned so the
# output is byte-reproducible. Used by the L3 adapter integration specs.
module FixtureRunner
  GEM_LIB = File.expand_path("../../lib", __dir__)

  module_function

  # Runs `bundle exec rspec` in the rspec_app fixture. Returns true on success.
  def run_rspec(fixture_dir:, map_path:, coverage_path: nil, timestamp: 1_753_142_400, commit: "TESTSHA")
    run(fixture_dir, "bundle exec rspec", map_path, coverage_path, timestamp, commit)
  end

  # Runs `bundle exec rake` in the minitest_app fixture.
  def run_minitest(fixture_dir:, map_path:, coverage_path: nil, timestamp: 1_753_142_400, commit: "TESTSHA")
    run(fixture_dir, "bundle exec rake", map_path, coverage_path, timestamp, commit)
  end

  def run(fixture_dir, command, map_path, coverage_path, timestamp, commit)
    env = {
      "TESTALARIA" => "1",
      "TESTALARIA_MAP" => File.expand_path(map_path),
      "TESTALARIA_TIMESTAMP" => timestamp.to_s,
      "TESTALARIA_COMMIT" => commit,
      # Inject the gem under test onto the fixture process's load path.
      "RUBYOPT" => "-I#{GEM_LIB} #{ENV['RUBYOPT']}".strip
    }
    env["TESTALARIA_COVERAGE"] = File.expand_path(coverage_path) if coverage_path
    Bundler.with_unbundled_env do
      system(env, "bundle install --quiet && #{command}", chdir: fixture_dir)
    end
  end
end
