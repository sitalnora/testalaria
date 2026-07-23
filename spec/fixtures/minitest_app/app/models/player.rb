# frozen_string_literal: true

require_relative "../support"

class Player
  extend Support::ClassMacros

  validates :name, presence: true

  def initialize(name)
    @name = name
  end

  def fn_one
    "one:#{@name}"
  end

  def fn_two
    fn_one.upcase
  end

  define_method(:dynamic_greet) do
    "hi #{@name}"
  end
end
