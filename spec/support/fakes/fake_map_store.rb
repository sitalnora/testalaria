# frozen_string_literal: true

# Test double for the Map store seam: keeps the map in memory instead of on
# disk. Round-trip + determinism tests exercise the real Psych-backed store on
# tmpdirs; unit tests that only need somewhere to persist use this.
#
# Interface (must match Testalaria::MapStore):
#   load        -> map hash (empty-ish default when never dumped)
#   dump(map)   -> writes, returns map
class FakeMapStore
  attr_reader :dumps # every map handed to dump, in order

  def initialize(initial: nil)
    @current = initial
    @dumps = []
  end

  def load
    @current || { commit: nil, timestamp: nil, version: 1 }
  end

  def dump(map)
    @dumps << map
    @current = map
  end
end
