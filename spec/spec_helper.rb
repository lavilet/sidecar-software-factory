require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "harness/paths"

RSpec.configure do |config|
  config.around do |example|
    previous = ENV["FACTORY_STATE_DIR"]
    Dir.mktmpdir("factory-test-state") do |state|
      ENV["FACTORY_STATE_DIR"] = state
      example.run
    end
  ensure
    ENV["FACTORY_STATE_DIR"] = previous
  end
end
