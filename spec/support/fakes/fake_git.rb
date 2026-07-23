# frozen_string_literal: true

# Test double for the Git seam. Fed canned data; the L2 contract suite proves
# it behaves identically to the real git-backed implementation against a
# tmpdir repo.
#
# Interface (must match Testalaria::Git):
#   head_sha                  -> sha string
#   merge_base(target)        -> sha string
#   changed_files(base)       -> [path, ...]
#   hunks(base, path)         -> [Range, ...] of changed line numbers at HEAD
#   file_at(sha, path)        -> source string (nil if absent at that sha)
class FakeGit
  def initialize(merge_base: "BASE", head_sha: "HEAD", changed_files: [], hunks: {}, files_at: {})
    @merge_base = merge_base
    @head_sha = head_sha
    @changed_files = changed_files
    @hunks = hunks             # { path => [Range, ...] }
    @files_at = files_at       # { [sha, path] => source }
  end

  def head_sha
    @head_sha
  end

  def merge_base(_target)
    @merge_base
  end

  def changed_files(_base)
    @changed_files
  end

  def hunks(_base, path)
    @hunks.fetch(path, [])
  end

  def file_at(sha, path)
    @files_at[[sha, path]]
  end
end
