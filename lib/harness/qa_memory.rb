require "fileutils"
require "json"
require "time"

module Harness
  # Persistent, zero-token-cost QA learning store at `profile runs/qa-memory.json`.
  # Automatically records verified working flows/selectors after passing Playwright runs
  # and blacklists flaky/broken selectors after non-crash selector failures so QA_PLANNER
  # continuously improves across runs and Retro can promote stable flows to profile qa/.
  class QaMemory
    MAX_FLOWS = 25
    MAX_FAILURES = 25

    def initialize(repo_root:)
      @path = File.join(Harness::Paths.profile(File.expand_path(repo_root)), "runs", "qa-memory.json")
    end

    attr_reader :path

    def load_data
      return default_data unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      return default_data unless parsed.is_a?(Hash)

      {
        "version" => 1,
        "verified_flows" => Array(parsed["verified_flows"]),
        "failed_selectors" => Array(parsed["failed_selectors"])
      }
    rescue JSON::ParserError
      default_data
    end

    def record_run!(scenario_path:, report:)
      return unless report.is_a?(Hash)

      scenario = read_scenario(scenario_path)
      return unless scenario

      data = load_data
      now = Time.now.utc.iso8601

      if report["passed"] == true
        record_passing_flow!(data, scenario: scenario, now: now)
      elsif pure_selector_failure?(report)
        record_selector_failure!(data, scenario: scenario, report: report, now: now)
      end

      save_data!(data)
      data
    end

    def format_prompt_section(max_flows: 8, max_failures: 10)
      data = load_data
      flows = Array(data["verified_flows"]).sort_by { |f| [ -f["passes"].to_i, -(f["last_passed_at"].to_s.length) ] }.first(max_flows)
      failures = Array(data["failed_selectors"]).sort_by { |f| -f["failures"].to_i }.first(max_failures)
      return "" if flows.empty? && failures.empty?

      sections = [ "\n## Learned QA Memory (auto-recorded from prior Playwright runs)" ]

      unless flows.empty?
        sections << "### Verified Working Flows & Selectors (reuse these!)"
        flows.each do |flow|
          paths = Array(flow["paths"]).join(" -> ")
          selectors = Array(flow["selectors"]).first(6).map { |s| "`#{s}`" }.join(", ")
          sections << "- **#{flow["name"]}** (passed #{flow["passes"]}x, routes: #{paths.empty? ? "(click-only)" : paths}): #{selectors}"
        end
      end

      unless failures.empty?
        sections << "\n### Previously Failed Selectors (DO NOT REUSE)"
        failures.each do |entry|
          loc = entry["path"] ? " on `#{entry["path"]}`" : ""
          sections << "- `#{entry["selector"]}`#{loc} (failed #{entry["failures"]}x): #{entry["reason"]}"
        end
      end

      "#{sections.join("\n")}\n"
    end

    def summary_for_retro
      data = load_data
      {
        "verified_flows_count" => Array(data["verified_flows"]).size,
        "top_verified_flows" => Array(data["verified_flows"]).sort_by { |f| -f["passes"].to_i }.first(8),
        "recurring_failed_selectors" => Array(data["failed_selectors"]).sort_by { |f| -f["failures"].to_i }.first(10)
      }
    end

    private
    def default_data
      { "version" => 1, "verified_flows" => [], "failed_selectors" => [] }
    end

    def read_scenario(scenario_path)
      return nil unless scenario_path && File.exist?(scenario_path)

      JSON.parse(File.read(scenario_path))
    rescue JSON::ParserError
      nil
    end

    def pure_selector_failure?(report)
      viewports = Array(report["viewports"])
      return false if viewports.empty?

      viewports.all? do |vp|
        Array(vp["http_5xx"]).empty? &&
          Array(vp["page_errors"]).empty? &&
          Array(vp["horizontal_overflow"]).empty?
      end
    end

    def record_passing_flow!(data, scenario:, now:)
      name = scenario["name"].to_s.strip
      return if name.empty?

      steps = Array(scenario["steps"])
      paths = steps.filter_map { |s| s["path"] if s["action"] == "goto" && !s["path"].to_s.empty? }.uniq
      selectors = steps.filter_map do |s|
        sel = s["selector"].to_s.strip
        sel unless sel.empty?
      end.uniq

      existing = data["verified_flows"].find { |f| f["name"] == name }
      if existing
        existing["paths"] = paths
        existing["selectors"] = selectors
        existing["passes"] = existing["passes"].to_i + 1
        existing["last_passed_at"] = now
      else
        data["verified_flows"] << {
          "name" => name,
          "paths" => paths,
          "selectors" => selectors,
          "passes" => 1,
          "last_passed_at" => now
        }
      end

      # Remove any selector from failed_selectors once proven working.
      data["failed_selectors"].reject! { |f| selectors.include?(f["selector"]) }
      data["verified_flows"] = data["verified_flows"].sort_by { |f| -f["passes"].to_i }.first(MAX_FLOWS)
    end

    def record_selector_failure!(data, scenario:, report:, now:)
      steps = Array(scenario["steps"])
      failed_vp = Array(report["viewports"]).find { |vp| vp["passed"] == false && !vp["failed_reason"].to_s.empty? }
      return unless failed_vp

      reason = failed_vp["failed_reason"].to_s.lines.first.to_s.strip[0, 180]
      failed_step_entry = Array(failed_vp["steps"]).find { |s| s["ok"] == false }
      step_index = failed_step_entry ? failed_step_entry["step"].to_i - 1 : nil
      step_def = step_index && step_index >= 0 ? steps[step_index] : nil

      selector = extract_failed_selector(step_def, failed_vp["failed_reason"].to_s)
      return if selector.empty?

      last_path = if step_index
        steps[0..step_index].reverse.find { |s| s["action"] == "goto" && s["path"] }&.fetch("path", nil)
      end

      existing = data["failed_selectors"].find { |f| f["selector"] == selector }
      if existing
        existing["failures"] = existing["failures"].to_i + 1
        existing["reason"] = reason
        existing["path"] = last_path if last_path
        existing["last_failed_at"] = now
      else
        data["failed_selectors"] << {
          "selector" => selector,
          "path" => last_path,
          "reason" => reason,
          "failures" => 1,
          "last_failed_at" => now
        }
      end

      data["failed_selectors"] = data["failed_selectors"].sort_by { |f| -f["failures"].to_i }.first(MAX_FAILURES)
    end

    def extract_failed_selector(step_def, raw_reason)
      if step_def
        sel = step_def["selector"].to_s.strip
        return sel unless sel.empty?

        txt = step_def["text"].to_s.strip
        return "text:#{txt}" unless txt.empty?
      end

      if (match = raw_reason.match(/locator\("(.+?)"\)/))
        return match[1]
      end
      if (match = raw_reason.match(/Expected text not found:\s*'(.+?)'/))
        return "text:#{match[1]}"
      end

      ""
    end

    def save_data!(data)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
