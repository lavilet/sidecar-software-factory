require "fileutils"

module Harness
  class Logger
    def initialize(log_path)
      @log_path = log_path
      FileUtils.mkdir_p(File.dirname(log_path))
    end

    def info(stage, message)
      line = "[#{Time.now.strftime("%H:%M:%S")}] [#{stage}] #{message}"
      $stdout.puts(line)
      $stdout.flush
      File.open(@log_path, "a") { |file| file.puts(line) }
    end
  end
end
