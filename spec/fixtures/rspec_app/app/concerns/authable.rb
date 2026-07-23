# frozen_string_literal: true

require_relative "../support"

# A concern that injects a before_action into whatever includes it — the exact
# "before_action via concern" indirection that static analysis can't follow but
# runtime coverage can.
module Authable
  def self.included(base)
    base.extend(Support::ClassMacros)
    base.before_action :authenticate
  end

  def authenticate
    @authenticated = true
  end
end
