require "fileutils"
require "json"
require "time"

module Harness
  # Persists completed pipeline stages per task so retries, restarts, and unblocked runs
  # resume from the last valid checkpoint instead of re-running Architect/Worker/QA from zero.
  class Checkpoint
    FILENAME = "checkpoint.json"

    def initialize(artifacts_dir:)
      @path = File.join(artifacts_dir, FILENAME)
    end

    attr_reader :path

    def load
      return {} unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def get(key)
      load[key.to_s]
    end

    def save(attrs)
      FileUtils.mkdir_p(File.dirname(@path))
      data = load.merge(stringify_keys(attrs)).merge("updated_at" => Time.now.utc.iso8601)
      tmp = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, @path)
      data
    end

    def clear!
      FileUtils.rm_f(@path)
    end

    private
    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
