require "fileutils"
require "json"
require "time"

module Harness
  class IssueStore
    def initialize(repo_root:)
      @dir = File.join(Harness::Paths.profile(File.expand_path(repo_root)), "runs", "issues")
      FileUtils.mkdir_p(@dir)
    end

    def find(issue_number)
      path = issue_path(issue_number)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def save(issue_number, data)
      payload = data.merge("issue_number" => issue_number.to_i, "updated_at" => Time.now.utc.iso8601)
      File.write(issue_path(issue_number), JSON.pretty_generate(payload))
      payload
    end

    def all
      Dir.glob(File.join(@dir, "*.json")).sort.filter_map do |path|
        next unless File.basename(path).match?(/\A\d+\.json\z/)

        JSON.parse(File.read(path))
      end
    end

    def artifact_path(filename)
      File.join(@dir, filename)
    end

    private
    def issue_path(issue_number)
      File.join(@dir, "#{issue_number}.json")
    end
  end
end
