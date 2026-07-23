# frozen_string_literal: true

require "rspec/core/rake_task"

# The gem's own test suite (L1 unit, L2 contract, L3 adapter integration,
# L4 e2e) is written in RSpec. L3/L4 shell out to the fixture apps' own
# suites as subprocesses — so the fixture specs under spec/fixtures/** must be
# excluded from the gem's own run (they only run inside those subprocesses).
RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/{unit,contract,integration,e2e}/**/*_spec.rb"
  t.rspec_opts = "-I spec" # so `require \"spec_helper\"` resolves
end

task default: :spec
