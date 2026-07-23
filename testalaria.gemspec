# frozen_string_literal: true

require_relative "lib/testalaria/version"

Gem::Specification.new do |spec|
  spec.name        = "testalaria"
  spec.version     = Testalaria::VERSION
  spec.authors     = ["Golf Genius"]
  spec.summary     = "Regression test selection for Ruby (RSpec + Minitest)"
  spec.description  = "Run only the tests a change could plausibly break, using " \
                      "runtime coverage recorded per example into a committed map. " \
                      "Framework-agnostic across RSpec and Minitest."
  spec.homepage    = "https://github.com/golfgenius/testalaria"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 2.7"

  # Explicit file list — the repo root contains unrelated placeholder dirs
  # (app/, config/) that must never be packaged.
  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
end
