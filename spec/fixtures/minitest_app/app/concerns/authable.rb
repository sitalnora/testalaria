# frozen_string_literal: true

require_relative "../support"

module Authable
  def self.included(base)
    base.extend(Support::ClassMacros)
    base.before_action :authenticate
  end

  def authenticate
    @authenticated = true
  end
end
