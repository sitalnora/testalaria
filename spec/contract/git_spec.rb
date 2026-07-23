# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

# L2 — Git seam contract. The real git-backed implementation is exercised
# against a repository the test builds in a tmpdir, and FakeGit is shown to
# return the same shapes for the same scenario. If they ever diverge, this
# fails — which is what licenses the unit layer to trust FakeGit.
RSpec.describe "Git seam contract" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def git(*args)
    _out, err, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end

  def write(rel, contents)
    File.write(File.join(@dir, rel), contents)
  end

  before do
    git "init", "-q", "-b", "main"
    git "config", "user.email", "t@example.com"
    git "config", "user.name", "Test"
    write("a.rb", "class A\n  def m\n    1\n  end\nend\n")
    git "add", "."
    git "commit", "-q", "-m", "base"
    @base_sha, = Open3.capture2("git", "-C", @dir, "rev-parse", "HEAD")
    @base_sha = @base_sha.strip

    git "checkout", "-q", "-b", "feature"
    write("a.rb", "class A\n  def m\n    2\n  end\nend\n") # line 3 changed
    write("b.rb", "class B\nend\n")                        # new file
    git "add", "."
    git "commit", "-q", "-m", "feature"
  end

  let(:real) { Testalaria::Git.new(dir: @dir) }
  let(:base) { real.merge_base("main") }

  it "merge_base returns the base commit sha" do
    expect(base).to eq(@base_sha)
  end

  it "head_sha returns the current commit, distinct from the base" do
    head, = Open3.capture2("git", "-C", @dir, "rev-parse", "HEAD")
    expect(real.head_sha).to eq(head.strip)
    expect(real.head_sha).not_to eq(@base_sha)
  end

  it "changed_files lists modified and added paths" do
    expect(real.changed_files(base)).to contain_exactly("a.rb", "b.rb")
  end

  it "hunks returns the changed line range at HEAD" do
    expect(real.hunks(base, "a.rb")).to eq([3..3])
  end

  it "file_at returns base content and nil for a path absent at base" do
    expect(real.file_at(base, "a.rb")).to include("    1")
    expect(real.file_at(base, "b.rb")).to be_nil
  end

  it "hunks for a newly added file cover all its lines" do
    expect(real.hunks(base, "b.rb")).to eq([1..2]) # b.rb is "class B\nend\n"
  end

  it "merge_base raises GitError for an unknown target" do
    expect { real.merge_base("definitely-not-a-branch") }.to raise_error(Testalaria::GitError)
  end

  it "FakeGit returns the same shapes for the same scenario" do
    fake = FakeGit.new(
      merge_base: @base_sha,
      changed_files: %w[a.rb b.rb],
      hunks: { "a.rb" => [3..3] },
      files_at: { [@base_sha, "a.rb"] => real.file_at(base, "a.rb") }
    )
    expect(fake.merge_base("main")).to eq(real.merge_base("main"))
    expect(fake.changed_files(base)).to match_array(real.changed_files(base))
    expect(fake.hunks(base, "a.rb")).to eq(real.hunks(base, "a.rb"))
    expect(fake.file_at(base, "b.rb")).to eq(real.file_at(base, "b.rb"))
  end
end

# Focused coverage of parse_hunks: which `@@` headers become ranges. A pure
# deletion (+count 0) must be skipped — deleted code is recovered by parsing
# the file at the base, not from a HEAD hunk.
RSpec.describe "Git seam hunk parsing" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def git(*args)
    _o, err, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end

  def commit_all(msg)
    git "add", "."
    git "commit", "-q", "-m", msg
  end

  let(:real) { Testalaria::Git.new(dir: @dir) }

  before do
    git "init", "-q", "-b", "main"
    git "config", "user.email", "t@example.com"
    git "config", "user.name", "Test"
    # a.rb: def m (2-4), def n (5-7).
    File.write(File.join(@dir, "a.rb"),
               "class A\n  def m\n    1\n  end\n  def n\n    2\n  end\nend\n")
    commit_all "base"
    git "checkout", "-q", "-b", "feature"
  end

  it "skips a pure-deletion hunk (+count 0) — deleted code is found at the base" do
    # Remove def n entirely (lines 5-7); nothing added at HEAD.
    File.write(File.join(@dir, "a.rb"), "class A\n  def m\n    1\n  end\nend\n")
    commit_all "delete n"
    expect(real.hunks(real.merge_base("main"), "a.rb")).to eq([])
  end

  it "returns one range per added/modified region" do
    # Edit both method bodies -> two disjoint single-line hunks.
    File.write(File.join(@dir, "a.rb"),
               "class A\n  def m\n    11\n  end\n  def n\n    22\n  end\nend\n")
    commit_all "edit both bodies"
    expect(real.hunks(real.merge_base("main"), "a.rb")).to eq([3..3, 6..6])
  end
end
