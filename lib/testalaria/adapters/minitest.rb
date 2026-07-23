# frozen_string_literal: true

require "testalaria/session"

module Testalaria
  module Adapters
    # Minitest adapter: prepends before_setup/after_teardown onto every test
    # and flushes once, after the whole run. Example id is the position-
    # independent "ClassName#test_method" — immune to the mid-file-insertion
    # renumbering that RSpec's index-based ids suffer.
    module Minitest
      module Hooks
        def before_setup
          super
          Testalaria::Session.current.start_example(testalaria_example_id)
        end

        def after_teardown
          Testalaria::Session.current.finish_example(testalaria_example_id)
          super
        end

        def testalaria_example_id
          "#{self.class.name}##{name}"
        end
      end

      def self.install!
        return unless Session.active?
        return unless defined?(::Minitest::Test)

        ::Minitest::Test.prepend(Hooks)
        ::Minitest.after_run { Session.current.flush }
      end
    end
  end
end
