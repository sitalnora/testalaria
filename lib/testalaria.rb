# frozen_string_literal: true

require "testalaria/version"

# Testalaria — regression test selection for Ruby >= 2.7.
#
# Run only the tests a change could plausibly break, instead of the whole
# suite. See test_selection_design.md for the full design.
#
# The public entry points are the rake tasks (testalaria:setup / :run / :lint);
# the modules below are the composable pieces behind them. Requires are added
# per build phase so the gem always loads with only the code that exists.
module Testalaria
  # Base class for every error the gem raises. Rescuing this catches all of
  # ours and nothing else.
  class Error < StandardError; end

  # Raised when the running Coverage session is in oneshot_lines mode, which
  # makes per-example diffing impossible. Fail loudly with remediation.
  class OneshotCoverageError < Error; end

  # Raised when configuration (.testalaria.config.yml) is missing or invalid.
  class ConfigError < Error; end

  # Raised when a source file cannot be parsed; selection escalates that file.
  class ParseError < Error; end

  # Raised for git-level problems (not a repo, missing target branch, etc.).
  class GitError < Error; end
end

# Phase 1 — collection core. Required after the error classes above so they are
# defined when these files load.
require "testalaria/def_index"
require "testalaria/resolver"
require "testalaria/map"
require "testalaria/map_store"
require "testalaria/coverage_source"
require "testalaria/coverage_digest"
require "testalaria/collector"
require "testalaria/session"

# Phase 2 — git + selection.
require "testalaria/git"
require "testalaria/stub_index"
require "testalaria/selector"

# Phase 3 — orchestration.
require "testalaria/config"
require "testalaria/runner"
require "testalaria/flow"
require "testalaria/setup"

# Phase 4 — report.
require "testalaria/rot_lint"
require "testalaria/report"
require "testalaria/cli"
