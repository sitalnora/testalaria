# frozen_string_literal: true

# Test double for the Clock seam. Exists purely so goldens are byte-stable:
# the map stamps :timestamp from the clock, and a fixed clock keeps that field
# constant across runs.
#
# Interface (must match Testalaria's clock seam):
#   now -> Time
class FixedClock
  DEFAULT = Time.utc(2025, 7, 22, 0, 0, 0) # 1753142400, matches the design doc

  def initialize(time = DEFAULT)
    @time = time
  end

  def now
    @time
  end
end
