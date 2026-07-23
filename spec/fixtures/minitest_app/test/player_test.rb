# frozen_string_literal: true

require_relative "test_helper"

class PlayerTest < Minitest::Test
  def test_fn_one_greets_with_the_name
    assert_equal "one:a", Player.new("a").fn_one
  end

  def test_fn_two_upcases_the_greeting
    assert_equal "ONE:A", Player.new("a").fn_two
  end

  def test_dynamic_greeter
    assert_equal "hi a", Player.new("a").dynamic_greet
  end
end
