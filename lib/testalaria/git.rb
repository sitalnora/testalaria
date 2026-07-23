# frozen_string_literal: true

require "open3"

module Testalaria
  # The Git seam: everything the selector needs to know about a PR's changes.
  # Diffs are computed against the merge-base with the target branch (the design's
  # triple-dot semantics), which is always reachable regardless of squash/rebase
  # merge policy. Historical file contents come from `git show <sha>:<path>`.
  class Git
    def initialize(dir: Dir.pwd)
      @dir = dir
    end

    # @return [String] the sha of HEAD (what the map's entries reflect)
    def head_sha
      capture("rev-parse", "HEAD").strip
    end

    # @return [String] merge-base sha of target and HEAD
    def merge_base(target)
      capture("merge-base", target, "HEAD").strip
    end

    # @return [Array<String>] paths changed between base and HEAD
    def changed_files(base)
      capture("diff", "--name-only", base, "HEAD").split("\n").reject(&:empty?)
    end

    # @return [Array<Range>] added/modified line ranges at HEAD for path
    def hunks(base, path)
      parse_hunks(capture("diff", "-U0", "--no-color", base, "HEAD", "--", path))
    end

    # @return [String, nil] file content at sha, or nil if absent there
    def file_at(sha, path)
      out, status = capture_status("show", "#{sha}:#{path}")
      status.success? ? out : nil
    end

    private

    def capture(*args)
      out, err, status = Open3.capture3("git", "-C", @dir, *args)
      raise GitError, "git #{args.join(' ')} failed: #{err.strip}" unless status.success?

      out
    end

    def capture_status(*args)
      out, _err, status = Open3.capture3("git", "-C", @dir, *args)
      [out, status]
    end

    # Extract the `+start,count` side of each `@@ ... @@` hunk header. count 0
    # (pure deletion, no HEAD lines) is skipped — deleted methods are found by
    # parsing the file at the base instead.
    def parse_hunks(diff)
      diff.each_line.filter_map do |line|
        next unless line.start_with?("@@")

        m = /\+(\d+)(?:,(\d+))?/.match(line)
        next unless m

        start = m[1].to_i
        count = m[2] ? m[2].to_i : 1
        next if count.zero?

        start..(start + count - 1)
      end
    end
  end
end
