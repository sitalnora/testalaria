# frozen_string_literal: true

require "fileutils"
require "testalaria/map"

module Testalaria
  # The Map store seam: reads/writes the map file on disk. Writes are atomic
  # (tmp file + rename) so an interrupted or crashing run leaves the previous
  # map intact rather than a half-written one.
  class MapStore
    DEFAULT_PATH = ".testalaria.yml"

    attr_reader :path

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # @return [Hash] the map hash, or an empty scaffold if the file is absent
    def load
      return Map.empty unless File.exist?(@path)

      Map.load(File.read(@path))
    end

    # Atomically serialize and write the map.
    def dump(map)
      yaml = Map.dump(map)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir == "." || Dir.exist?(dir)
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.write(tmp, yaml)
      File.rename(tmp, @path)
      map
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
