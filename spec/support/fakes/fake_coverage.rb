# frozen_string_literal: true

# Test double for the Coverage source seam. Fed a scripted sequence of peek
# snapshots so the collector's before/after diffing can be tested without a
# real Coverage session. The L2 layer runs one real-Coverage smoke test per
# Ruby version to license this fake.
#
# Interface (must match Testalaria::Collector's coverage seam):
#   running? -> bool
#   mode     -> :lines | :oneshot_lines | ...
#   peek     -> normalized { file => [counts] }
class FakeCoverage
  def initialize(snapshots: [], running: true, mode: :lines)
    @snapshots = snapshots   # Array of { file => [counts] }
    @running = running
    @mode = mode
    @cursor = 0
  end

  def running?
    @running
  end

  # Session calls this on init. The fake is pre-scripted, so starting is a
  # no-op beyond flipping the running flag.
  def start(*)
    @running = true
  end

  attr_reader :mode

  # Returns the next scripted snapshot, repeating the last one once exhausted.
  def peek
    snap = @snapshots[@cursor] || @snapshots.last || {}
    @cursor += 1 if @cursor < @snapshots.length
    deep_dup(snap)
  end

  private

  def deep_dup(snap)
    snap.each_with_object({}) { |(file, counts), acc| acc[file] = counts.dup }
  end
end
