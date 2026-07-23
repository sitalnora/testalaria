# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# L3 — adapter integration. Runs each fixture app's real suite as a subprocess
# under TESTALARIA=1 and asserts the produced map. Tagged :integration; run with
# TESTALARIA_INTEGRATION=1 (and the fixture bundles installable).
RSpec.describe "adapter integration", :integration do
  def fixture(name)
    File.join(::RSpec.configuration.fixtures_root, name)
  end

  # Every method the map records anywhere, flattened.
  def all_methods(map)
    Testalaria::Map.example_keys(map).flat_map { |k| map[k].values }.flatten.uniq
  end

  describe "RSpec adapter" do
    it "records a method-granular map, byte-identical across two runs" do
      Dir.mktmpdir do |dir|
        map1 = File.join(dir, "map1.yml")
        map2 = File.join(dir, "map2.yml")

        expect(FixtureRunner.run_rspec(fixture_dir: fixture("rspec_app"), map_path: map1)).to be(true)
        expect(FixtureRunner.run_rspec(fixture_dir: fixture("rspec_app"), map_path: map2)).to be(true)

        # System-level determinism.
        expect(File.read(map1)).to eq(File.read(map2))

        map = Testalaria::Map.load(File.read(map1))
        # The suite exercised Player#fn_one/#fn_two through the model and the
        # controller; the map is keyed by RSpec position ids.
        expect(all_methods(map)).to include("Player#fn_one", "Player#fn_two", "OneController#index")
        expect(Testalaria::Map.example_keys(map)).to(be_all { |k| k.start_with?("./spec/") })
      end
    end

    it "writes a coverage digest of executed source lines" do
      Dir.mktmpdir do |dir|
        map = File.join(dir, "map.yml")
        cov = File.join(dir, "coverage.yml")

        expect(FixtureRunner.run_rspec(fixture_dir: fixture("rspec_app"), map_path: map, coverage_path: cov)).to be(true)

        digest = Testalaria::CoverageDigestStore.new(path: cov).load
        player = digest.keys.find { |k| k.end_with?("app/models/player.rb") }
        expect(player).not_to be_nil
        expect(digest[player]).to include(3) # Player#fn_one body executed
      end
    end
  end

  describe "Minitest adapter" do
    it "records a map keyed by ClassName#test_method" do
      Dir.mktmpdir do |dir|
        map_path = File.join(dir, "map.yml")

        expect(FixtureRunner.run_minitest(fixture_dir: fixture("minitest_app"), map_path: map_path)).to be(true)

        map = Testalaria::Map.load(File.read(map_path))
        keys = Testalaria::Map.example_keys(map)
        expect(keys).to include("PlayerTest#test_fn_one_greets_with_the_name")
        expect(all_methods(map)).to include("Player#fn_one")
      end
    end
  end
end
