# frozen_string_literal: true

require "testalaria/session"

module Testalaria
  module Adapters
    # RSpec adapter: snapshots around each example and flushes at suite end.
    # The example id is RSpec's native position address, e.g.
    # "./spec/player_spec.rb[1:2:1]".
    module RSpec
      # Install hooks into the running RSpec config. No-op unless TESTALARIA=1.
      def self.install!(session: nil)
        return unless Session.active?
        return unless defined?(::RSpec)

        session ||= Session.current

        ::RSpec.configure do |config|
          config.prepend_before(:each) { |example| session.start_example(example.id) }
          config.append_after(:each) { |example| session.finish_example(example.id) }
          config.after(:suite) { session.flush }
        end
      end
    end
  end
end
