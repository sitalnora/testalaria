# frozen_string_literal: true

require_relative "test_helper"

class OneControllerTest < Minitest::Test
  def test_index_authenticates_and_greets
    assert_equal "one:aron", OneController.new.index
  end

  def test_concern_registers_before_action
    assert_includes OneController.before_actions, :authenticate
  end
end
