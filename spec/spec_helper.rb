# frozen_string_literal: true

require "testalaria"

# Load shared test support (fakes/seams, shared contract examples, helpers).
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined # deterministic; goldens depend on stable ordering
  config.default_formatter = "doc" if config.files_to_run.one?

  # Absolute path to the fixture apps, used by L3/L4 subprocess tests.
  config.add_setting :fixtures_root, default: File.expand_path("fixtures", __dir__)

  # L3/L4 subprocess tests are slow and need the fixture bundles installed.
  # They run in CI and when opted into locally; the fast L1 unit suite skips
  # them by default.
  unless ENV["TESTALARIA_INTEGRATION"] == "1"
    config.filter_run_excluding(:integration)
  end
end
