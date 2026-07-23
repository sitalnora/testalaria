# frozen_string_literal: true

# Minimal Rails-ish DSL — see the rspec_app copy for rationale. Kept as a
# separate file so each fixture app is fully self-contained.
module Support
  module ClassMacros
    def validations
      @validations ||= []
    end

    def validates(*args)
      validations << args
    end

    def before_actions
      @before_actions ||= []
    end

    def before_action(sym)
      before_actions << sym
    end
  end
end
