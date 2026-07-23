# frozen_string_literal: true

# Test double for the Framework adapter seam. Lets a test drive the collector
# by hand — start an example, declare which files/lines it "touched", finish —
# without booting RSpec or Minitest. The real adapters are exercised in L3
# against the fixture apps.
#
# Interface (must match the adapter contract):
#   example_id                  -> stable id string for the current example
#   on_example_start            -> snapshot hook
#   on_example_finish(touched)  -> { file => [lines] } handed to resolver + map
class FakeAdapter
  attr_reader :started, :finished

  def initialize
    @current_id = nil
    @started = []
    @finished = []
  end

  # Test helper: simulate one example lifecycle around a block.
  def example(id)
    @current_id = id
    on_example_start
    touched = yield
    on_example_finish(touched)
  ensure
    @current_id = nil
  end

  def example_id
    @current_id
  end

  def on_example_start
    @started << @current_id
  end

  def on_example_finish(touched)
    @finished << [@current_id, touched]
  end
end
