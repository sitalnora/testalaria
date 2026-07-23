# frozen_string_literal: true

require "testalaria"
require "testalaria/adapters/rspec"

# Convenience entry point for RSpec projects. Add to your `.rspec`:
#
#   --require testalaria/rspec
#
# (or `require "testalaria/rspec"` in spec_helper). Installing the collector is
# a no-op unless TESTALARIA=1, so this is safe to load unconditionally in CI and
# locally — it only activates under `rake testalaria:setup` / `:run`.
Testalaria::Adapters::RSpec.install!
