# frozen_string_literal: true

# Test double for the Process runner seam. Records every invocation (command
# + env) and returns scripted results, so e2e tests can assert exactly which
# suite commands ran with which targets — without running a real suite.
#
# Interface (must match Testalaria::Runner's process seam):
#   run(cmd, env:) -> Result(exit_status:, stdout:)
class FakeRunner
  Result = Struct.new(:exit_status, :stdout, keyword_init: true)

  # calls: recorded [{cmd:, env:}, ...]
  attr_reader :calls

  # scripted: Array of Result (or Hash) returned in order; a single Result/Hash
  # is reused for every call. Defaults to a clean exit with empty stdout.
  def initialize(scripted: nil)
    @calls = []
    @scripted = Array(scripted)
  end

  def run(cmd, env: {})
    @calls << { cmd: cmd, env: env }
    scripted = @scripted[@calls.length - 1] || @scripted.last
    coerce(scripted)
  end

  private

  def coerce(scripted)
    case scripted
    when Result then scripted
    when Hash   then Result.new(**scripted)
    when nil    then Result.new(exit_status: 0, stdout: "")
    else raise ArgumentError, "unscriptable runner result: #{scripted.inspect}"
    end
  end
end
