require "fileutils"
require "json"

module Harness
  class Telemetry
    def initialize(path)
      @path = path
      FileUtils.mkdir_p(File.dirname(path))
    end

    def record(event)
      File.open(@path, "a") do |file|
        file.puts(JSON.generate(event))
      end
    end
  end
end
