# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Testalaria::Setup do
  describe ".append_gitignore" do
    it "creates .gitignore listing the ephemeral report/coverage artifacts" do
      Dir.mktmpdir do |dir|
        gi = File.join(dir, ".gitignore")
        described_class.append_gitignore(path: gi)
        expect(File.read(gi).split("\n")).to contain_exactly(
          ".testalaria.report.yml", ".testalaria.coverage.yml"
        )
      end
    end

    it "is idempotent and preserves existing entries without blank lines" do
      Dir.mktmpdir do |dir|
        gi = File.join(dir, ".gitignore")
        File.write(gi, "node_modules\n.testalaria.report.yml\n")
        2.times { described_class.append_gitignore(path: gi) }
        expect(File.read(gi).split("\n")).to eq(
          ["node_modules", ".testalaria.report.yml", ".testalaria.coverage.yml"]
        )
      end
    end

    it "does not list the committed map or config" do
      Dir.mktmpdir do |dir|
        gi = File.join(dir, ".gitignore")
        described_class.append_gitignore(path: gi)
        contents = File.read(gi)
        expect(contents).not_to include(".testalaria.yml\n")
        expect(contents).not_to include(".testalaria.config.yml")
      end
    end
  end
end
