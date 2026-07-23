# frozen_string_literal: true

# Fixture app spec helper. Loads the app under test. In Phase 1+, the gem's
# RSpec adapter is required here (or via .rspec) under TESTALARIA=1 so the
# collector records a map for this suite.
app = File.expand_path("../app", __dir__)
require File.join(app, "models", "player")
require File.join(app, "controllers", "one_controller")

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :defined # deterministic example ids for the golden map
end

# Real projects add `--require testalaria/rspec` to .rspec instead of this
# block; the fixture guards on the env so it still runs standalone (without the
# gem on the load path).
require "testalaria/rspec" if ENV["TESTALARIA"] == "1"
