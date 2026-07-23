# frozen_string_literal: true

require "minitest/autorun"

# Fixture app test helper. In Phase 1+, the gem's Minitest plugin is loaded
# here under TESTALARIA=1 so the collector records a map for this suite.
app = File.expand_path("../app", __dir__)

# No wiring needed: under TESTALARIA=1 the bundled Minitest plugin
# (lib/minitest/testalaria_plugin.rb) is auto-discovered and installs the
# collector — this is exactly what a real project gets for free.
require File.join(app, "models", "player")
require File.join(app, "controllers", "one_controller")
