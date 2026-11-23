module Harness
  # Parses lightweight Epic/dependency metadata from GitHub Issue bodies.
  # Supports both inline metadata lines:
  #   Parent: #41
  #   Depends on: #42, #43
  #   Pilot: true
  # and Markdown section headings (e.g. factory-planning format):
  #   ## Dependencies
  #   #42
  module EpicParser
    Metadata = Data.define(:parent_issue, :depends_on, :pilot)

    def self.parse(body)
      text = body.to_s
      parent_match = text.match(/^\s*Parent:\s*#(\d+)/i)
      parent_issue = parent_match ? parent_match[1].to_i : nil

      depends_on = []
      text.scan(/^\s*Depends\s+on:\s*(.+)$/i).each do |match|
        depends_on.concat(match[0].scan(/#(\d+)/).flatten.map(&:to_i))
      end

      deps_section = text.match(/^##\s+Dependencies\s*\r?\n(.*?)(?=^##\s|\z)/im)
      if deps_section
        depends_on.concat(deps_section[1].scan(/#(\d+)/).flatten.map(&:to_i))
      end
      depends_on = depends_on.uniq

      pilot = text.match?(/^\s*Pilot:\s*(true|yes|1)\b/i) ||
        text.match?(/^##\s+Outcome\s*\r?\n\s*Pilot\b/i)

      Metadata.new(parent_issue: parent_issue, depends_on: depends_on, pilot: pilot)
    end
  end
end
