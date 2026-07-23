# frozen_string_literal: true

require_relative "../support"

class Player
  extend Support::ClassMacros

  # Class-body code: no enclosing def, recorded under "(toplevel)".
  validates :name, presence: true

  def initialize(name)
    @name = name
  end

  def fn_one
    "one:#{@name}"
  end

  # Reaches fn_one transitively — the map should still record a direct edge
  # from the example to fn_two (and to fn_one, since both lines execute).
  def fn_two
    fn_one.upcase
  end

  # Dynamic definition: no parseable `def`, must be flagged, not indexed.
  define_method(:dynamic_greet) do
    "hi #{@name}"
  end
end
