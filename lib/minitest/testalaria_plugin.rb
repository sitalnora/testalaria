# frozen_string_literal: true

# Minitest auto-discovers `lib/minitest/*_plugin.rb` on the load path and calls
# `Minitest.plugin_<name>_init`. So a project that bundles testalaria gets the
# collector with ZERO configuration — this fires automatically, and does nothing
# unless TESTALARIA=1 (so ordinary `rake test` runs are unaffected).
module Minitest
  def self.plugin_testalaria_init(_options)
    return unless ENV["TESTALARIA"] == "1"

    require "testalaria"
    require "testalaria/adapters/minitest"
    Testalaria::Adapters::Minitest.install!
  end
end
