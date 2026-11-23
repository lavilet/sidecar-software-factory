require "fileutils"
require "json"
require "open3"
require "time"

module Harness
  # Autonomous read-only Scout that scans the target project and telemetry.jsonl for concrete,
  # high-leverage improvements and opens deduplicated proposal issues (agent:needs-info).
  class Scout
    SCOUT_MARKER = "<!-- HARNESS_SCOUT -->"

    def initialize(repo_root:, backend:, model: nil, reasoning_effort: nil, logger:, github: nil)
      @repo_root = File.expand_path(repo_root)
      @backend = backend
      @model = model
      @reasoning_effort = reasoning_effort
      @logger = logger
      @github = github
    end

    def call(create_issues: false, max_issues: 2, dry_run: false)
      runs_dir = File.join(Harness::Paths.profile(@repo_root), "runs")
      FileUtils.mkdir_p(runs_dir)

      existing_titles = fetch_open_issue_titles
      telemetry_summary = read_telemetry_summary
      prompt = build_prompt(existing_titles: existing_titles, telemetry_summary: telemetry_summary)

      timestamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      prompt_path = File.join(runs_dir, "scout-#{timestamp}-prompt.md")
      File.write(prompt_path, prompt)

      if dry_run
        @logger.info("SCOUT", "[dry-run] Wrote scout prompt to #{prompt_path}")
        return { prompt_path: prompt_path, created_issues: [] }
      end

      schema_path = File.join(Harness::Paths::ROOT, "schemas", "scout.json")
      out_json = File.join(runs_dir, "scout-#{timestamp}.json")

      result = @backend.run(
        stage: "SCOUT[#{@backend.name}]",
        role: "architect",
        worktree_dir: @repo_root,
        prompt: prompt,
        output_file: out_json,
        sandbox: "read-only",
        model: @model,
        reasoning_effort: @reasoning_effort,
        output_schema: schema_path
      )

      report = JSON.parse(result.output)
      deduped = deduplicate_findings(Array(report["findings"]), existing_titles)
      report["findings"] = deduped
      File.write(out_json, JSON.pretty_generate(report))
      File.write(File.join(runs_dir, "scout-latest.json"), JSON.pretty_generate(report))

      created = []
      if create_issues
        deduped.first(max_issues).each do |finding|
          url = open_proposal_issue(finding)
          created << { id: finding["id"], title: finding["title"], url: url }
        end
      end

      @logger.info("SCOUT", "Found #{deduped.size} concrete finding(s), opened #{created.size} proposal issue(s)")
      { report: report, report_path: out_json, created_issues: created }
    end

    private
    def fetch_open_issue_titles
      out, status = Open3.capture2e("gh", "issue", "list", "--state", "open", "--limit", "50", "--json", "title", chdir: @repo_root)
      return [] unless status.success?

      JSON.parse(out).map { |row| row["title"].to_s }
    rescue JSON::ParserError
      []
    end

    def read_telemetry_summary
      path = File.join(Harness::Paths.profile(@repo_root), "runs", "telemetry.jsonl")
      return {} unless File.exist?(path)

      events = File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      runs = events.reject { |e| e["event"] == "pr_outcome" || e["dry_run"] == true }
      failures = Hash.new(0)
      runs.each { |r| Array(r["failure_categories"]).each { |c| failures[c] += 1 } }

      {
        total_runs: runs.size,
        avg_tokens: runs.empty? ? 0 : (runs.sum { |r| r.dig("usage", "total_tokens").to_i } / runs.size),
        total_cost_usd: runs.sum { |r| r["estimated_cost_usd"].to_f }.round(4),
        top_failure_categories: failures.sort_by { |_, v| -v }.to_h
      }
    end

    def deduplicate_findings(findings, existing_titles)
      normalized_existing = existing_titles.map { |t| normalize_title(t) }
      findings.reject do |finding|
        norm = normalize_title(finding["title"])
        normalized_existing.any? { |existing| existing.include?(norm) || norm.include?(existing) }
      end
    end

    def normalize_title(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def open_proposal_issue(finding)
      body = <<~MD
          #{SCOUT_MARKER}
          ### Autonomous Scout Proposal (`#{finding["category"]}`)
          - **Playbook:** `#{finding["playbook"]}` | **Risk:** `#{finding["risk_level"]}`
          - **Evidence:** #{finding["evidence"]}

          ### Brief
          #{finding["brief"]}

          ### Hard Stop Condition (`done_if`)
          #{finding["done_if"]}

          _Switch label to `agent:triage` (or `agent:ready` after triage) if you want the harness to execute this._
        MD

      if @github && @github.respond_to?(:create_issue)
        @github.create_issue(title: "[scout] #{finding["title"]}", body: body, label: "agent:needs-info")
      else
        out, status = Open3.capture2e(
          "gh", "issue", "create",
          "--title", "[scout] #{finding["title"]}",
          "--body", body,
          "--label", "agent:needs-info",
          chdir: @repo_root
        )
        raise CommandError, "gh issue create failed:\n#{out}" unless status.success?

        out.strip
      end
    end

    def build_prompt(existing_titles:, telemetry_summary:)
      rules_index = File.read(File.join(Harness::Paths.profile(@repo_root), "rules", "index.md")).strip
      titles_block = existing_titles.empty? ? "_None_" : existing_titles.map { |t| "- #{t}" }.join("\n")

      <<~PROMPT
          You are the AUTONOMOUS ENGINEERING SCOUT for the target project (read-only mode). Do NOT edit files.
          Inspect the live codebase and telemetry to discover at most 3 concrete, high-leverage improvements backed by exact `file:line` evidence.

          Focus on these 4 lenses:
          1. `architecture`: drift from documented interfaces and ownership.
          2. `performance_security`: inefficient hot paths and missing safeguards in changed code.
          3. `tests_ui_dx`: unverified public behavior and repeated developer friction.
          4. `harness_efficiency`: ways to reduce token usage, verify loops, or cost based on telemetry.

          Do NOT propose anything that duplicates the already-open GitHub Issues below.

          ## Already Open GitHub Issues
          #{titles_block}

          ## Recent Harness Telemetry
          ```json
          #{JSON.pretty_generate(telemetry_summary)}
          ```

          ## Current `profile rules/index.md`
          #{rules_index}
        PROMPT
    end
  end
end
