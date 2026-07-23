# frozen_string_literal: true

# Minimal Rails-ish DSL so the fixture reproduces the parser hard cases
# (class-body macros, concern-provided callbacks) without a Rails dependency.
# Testalaria only cares how these *parse* and which lines execute, not what
# they do — so no-op recorders are enough.
module Support
  module ClassMacros
    def validations
      @validations ||= []
    end

    # Class-body macro: runs at load time, has no enclosing def -> "(toplevel)".
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
