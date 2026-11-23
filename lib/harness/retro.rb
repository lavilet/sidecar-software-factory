require "fileutils"
require "json"
require "open3"
require "time"
require_relative "qa_memory"

module Harness
  # Post-merge self-improvement loop ("Harness Retro").
  # Analyzes merged PRs (human edits + PR review comments) and telemetry.jsonl
  # to propose at most 3 high-leverage upgrades (linters, tests, generators,
  # shared UI components, playbooks, or rule pruning).
  class Retro
    RETRO_MARKER = "<!-- HARNESS_RETRO -->"
    BOT_MARKER = "<!-- HARNESS_BOT -->"

    def initialize(repo_root:, store:, backend:, model: nil, reasoning_effort: nil, logger:, upgrade_runner: nil, github: nil)
      @repo_root = File.expand_path(repo_root)
      @store = store
      @backend = backend
      @model = model
      @reasoning_effort = reasoning_effort
      @logger = logger
      @upgrade_runner = upgrade_runner
      @github = github
    end

    def call(include_all_merged: false, propose_pr: false, create_issues: false, max_issues: 2, dry_run: false)
      candidates = select_merged_issues(include_all_merged: include_all_merged)
      telemetry_summary = summarize_telemetry

      if candidates.empty? && telemetry_summary[:total_runs].zero?
        @logger.info("RETRO", "No unprocessed merged PRs or telemetry runs found; skipping retro.")
        return nil
      end

      timestamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      runs_dir = File.join(Harness::Paths.profile(@repo_root), "runs")
      FileUtils.mkdir_p(runs_dir)

      existing_titles = create_issues ? fetch_open_issue_titles : []
      prompt = build_prompt(candidates: candidates, telemetry_summary: telemetry_summary, existing_titles: existing_titles)
      prompt_path = File.join(runs_dir, "retro-#{timestamp}-prompt.md")
      File.write(prompt_path, prompt)

      if dry_run
        @logger.info("RETRO", "[dry-run] Wrote retro prompt to #{prompt_path}")
        return { prompt_path: prompt_path, issues_count: candidates.size, created_issues: [] }
      end

      schema_path = File.join(Harness::Paths::ROOT, "schemas", "retro.json")
      json_out = File.join(runs_dir, "retro-#{timestamp}.json")

      raw = @backend.run(
        stage: "RETRO[#{@backend.name}]",
        role: "retro",
        worktree_dir: @repo_root,
        prompt: prompt,
        output_file: json_out,
        sandbox: "read-only",
        model: @model,
        reasoning_effort: @reasoning_effort,
        output_schema: schema_path
      )

      report = JSON.parse(raw.output)
      report_md_path = File.join(runs_dir, "retro-#{timestamp}.md")
      File.write(report_md_path, format_markdown_report(report, telemetry_summary: telemetry_summary, candidates: candidates))
      issue_numbers = candidates.map { |c| c["issue_number"] }
      record_lessons(report, issue_numbers: issue_numbers)

      candidates.each do |record|
        @store.save(record["issue_number"], record.merge("retro_processed" => true, "retro_report" => report_md_path))
      end

      created_issues = []
      if create_issues
        upgrades = deduplicate_upgrades(
          Array(report["proposed_upgrades"]).sort_by { |u| u["priority"].to_i },
          existing_titles
        )
        upgrades.first(max_issues).each do |upgrade|
          url = open_upgrade_issue(upgrade, issue_numbers: issue_numbers)
          created_issues << { id: upgrade["id"], title: upgrade["title"], url: url }
        end
      end

      pr_url = nil
      if propose_pr && @upgrade_runner
        top_upgrade = Array(report["proposed_upgrades"]).min_by { |u| u["priority"].to_i }
        if top_upgrade
          @logger.info("RETRO", "Delegating top upgrade '#{top_upgrade["id"]}' to runner (--propose-pr)")
          pr_url = @upgrade_runner.call(top_upgrade)
        end
      end

      @logger.info(
        "RETRO",
        "Report written to #{report_md_path} (lessons=#{Array(report["lessons"]).size}, " \
        "upgrades=#{Array(report["proposed_upgrades"]).size}, issues_opened=#{created_issues.size})"
      )
      { report: report, report_path: report_md_path, pr_url: pr_url, created_issues: created_issues }
    end

    def summarize_telemetry
      path = File.join(Harness::Paths.profile(@repo_root), "runs", "telemetry.jsonl")
      return empty_summary unless File.exist?(path)

      events = File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      run_events = events.reject { |e| e["event"] == "pr_outcome" || e["dry_run"] == true }
      outcome_events = events.select { |e| e["event"] == "pr_outcome" }

      failure_counts = Hash.new(0)
      run_events.each do |e|
        Array(e["failure_categories"]).each { |cat| failure_counts[cat] += 1 }
      end

      first_pass = run_events.count { |e| e["verify_loops"].to_i == 1 && Array(e["failure_categories"]).empty? }
      disagreements = run_events.sum { |e| e["review_disagreements"].to_i }
      total_tokens = run_events.sum { |e| e.dig("usage", "total_tokens").to_i }
      total_cost = run_events.sum { |e| e["estimated_cost_usd"].to_f }.round(4)
      avg_tokens = run_events.empty? ? 0 : (total_tokens / run_events.size)
      budget_exceeded_count = run_events.count { |e| e["budget_exceeded"] == true }
      merged_clean = outcome_events.count { |e| e["outcome"] == "merged_clean" }
      merged_edited = outcome_events.count { |e| e["outcome"] == "merged_edited" }
      abandoned = outcome_events.count { |e| e["outcome"] == "abandoned" }

      {
        total_runs: run_events.size,
        first_pass_verify_count: first_pass,
        review_disagreements: disagreements,
        total_tokens: total_tokens,
        avg_tokens_per_run: avg_tokens,
        total_estimated_cost_usd: total_cost,
        budget_exceeded_runs: budget_exceeded_count,
        top_failure_categories: failure_counts.sort_by { |_, count| -count }.to_h,
        merged_clean: merged_clean,
        merged_edited: merged_edited,
        abandoned: abandoned
      }
    end

    private
    def empty_summary
      {
        total_runs: 0,
        first_pass_verify_count: 0,
        review_disagreements: 0,
        top_failure_categories: {},
        merged_clean: 0,
        merged_edited: 0,
        abandoned: 0
      }
    end

    def select_merged_issues(include_all_merged:)
      @store.all.select do |record|
        record["state"] == "merged" && (include_all_merged || record["retro_processed"] != true)
      end
    end

    def record_lessons(report, issue_numbers:)
      lessons_path = File.join(Harness::Paths.profile(@repo_root), "runs", "lessons.jsonl")
      recorded_at = Time.now.utc.iso8601

      File.open(lessons_path, "a") do |file|
        Array(report["lessons"]).each do |lesson|
          file.puts(JSON.generate(lesson.merge("issue_numbers" => issue_numbers, "recorded_at" => recorded_at)))
        end
      end
    end

    def build_prompt(candidates:, telemetry_summary:, existing_titles: [])
      rules_index = File.read(File.join(Harness::Paths.profile(@repo_root), "rules", "index.md")).strip
      titles_block = existing_titles.empty? ? "_None_" : existing_titles.map { |t| "- #{t}" }.join("\n")

      merged_sections = candidates.map do |record|
        diff_text = read_truncated(record["human_diff_path"], 12_000)
        reviews_text = compact_review_evidence(record["reviews_snapshot_path"], max_bytes: 12_000)

        <<~ITEM
            ### Issue ##{record["issue_number"]} / PR ##{record["pr_number"]} (#{record["kind"]}, playbook: #{record["playbook"]})
            - Outcome: `#{record["outcome"]}` | Human diff lines: #{record["human_diff_lines"]} | Review fix rounds: #{record["review_fix_rounds"]}

            #### Human Edits After Agent (`agent_head_sha..merge_sha`)
            ```diff
            #{diff_text.empty? ? "(none)" : diff_text}
            ```

            #### GitHub PR Reviews & Inline Comments (Human Feedback First)
            #{reviews_text.empty? ? "_No human review comments recorded._" : reviews_text}
          ITEM
      end.join("\n\n")

      <<~PROMPT
          You are the HARNESS RETRO ARCHITECT for the target project (read-only mode).
          Your job is NOT to fix application features. Your job is to improve the harness, deterministic checks,
          tests, linters, project generators, shared UI components, and playbooks so recurring mistakes stop happening.

          ## Strict Leverage Hierarchy (strongest first)
          Use the project verification gate, targeted tests and maintainable tools for recurring failures.
          Suggest a concrete example or playbook edit when human judgment is required.
          For automatic upgrade PRs, propose changes that belong in the target repository.
          Describe operator-owned profile changes separately in lessons.

          Propose at most 3 concrete, actionable `proposed_upgrades` ordered by `priority` (1 = highest leverage).
          Do NOT propose upgrades that duplicate the already-open GitHub Issues listed below.
          Flag painful `merged_edited` or multi-round PRs as `eval_candidates` for held-out regression tests.

          ## Already Open GitHub Issues
          #{titles_block}

          ## Telemetry Summary (`profile runs/telemetry.jsonl`)
          ```json
          #{JSON.pretty_generate(telemetry_summary)}
          ```

          ## Learned QA Memory (`profile runs/qa-memory.json`)
          ```json
          #{JSON.pretty_generate(QaMemory.new(repo_root: @repo_root).summary_for_retro)}
          ```

          ## Merged PR Evidence (#{candidates.size})
          #{merged_sections.empty? ? "_No newly merged PRs; focus on telemetry failure categories._" : merged_sections}

          ## Current `profile rules/index.md`
          #{rules_index}
        PROMPT
    end

    def compact_review_evidence(path, max_bytes: 12_000)
      return "" unless path && File.exist?(path)

      payload = JSON.parse(File.read(path))
      inline = Array(payload["inline_comments"]).reject { |c| c["body"].to_s.include?(BOT_MARKER) || c["body"].to_s.strip.empty? }
      reviews = Array(payload["reviews"]).reject { |r| r["body"].to_s.include?(BOT_MARKER) || r["body"].to_s.strip.empty? }

      entries = []
      inline.each do |c|
        loc = [ c["path"], c["line"] || c["original_line"] ].compact.join(":")
        hunk = c["diff_hunk"].to_s.lines.last(4).join.strip
        block = "- **Inline `#{loc}`**: #{c["body"].to_s.strip}"
        block += "\n  ```diff\n  #{hunk.gsub("\n", "\n  ")}\n  ```" unless hunk.empty?
        entries << block
      end

      reviews.each do |r|
        state = r["state"].to_s.upcase
        entries << "- **Review (#{state.empty? ? "COMMENTED" : state})**: #{r["body"].to_s.strip}"
      end

      return "" if entries.empty?

      kept = []
      used = 0
      omitted = 0
      entries.each do |entry|
        cost = entry.bytesize + 1
        if kept.empty? || used + cost <= max_bytes
          kept << (entry.bytesize > max_bytes ? "#{entry.byteslice(0, max_bytes)}..." : entry)
          used += cost
        else
          omitted += 1
        end
      end

      kept << "_(#{omitted} additional review item(s) omitted due to budget)_" if omitted > 0
      kept.join("\n")
    rescue JSON::ParserError
      read_truncated(path, max_bytes)
    end

    def fetch_open_issue_titles
      if @github && @github.respond_to?(:open_issue_titles)
        return Array(@github.open_issue_titles)
      end

      out, status = Open3.capture2e("gh", "issue", "list", "--state", "open", "--limit", "50", "--json", "title", chdir: @repo_root)
      return [] unless status.success?

      JSON.parse(out).map { |row| row["title"].to_s }
    rescue JSON::ParserError
      []
    end

    def deduplicate_upgrades(upgrades, existing_titles)
      normalized_existing = existing_titles.map { |t| normalize_title(t) }.reject(&:empty?)
      upgrades.reject do |upgrade|
        norm = normalize_title(upgrade["title"])
        next true if norm.empty?

        normalized_existing.any? { |existing| existing.include?(norm) || norm.include?(existing) }
      end
    end

    def normalize_title(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def open_upgrade_issue(upgrade, issue_numbers:)
      targets = Array(upgrade["target_files"]).map { |f| "`#{f}`" }.join(", ")
      source = issue_numbers.empty? ? "telemetry" : issue_numbers.map { |n| "##{n}" }.join(", ")
      body = <<~MD
          #{RETRO_MARKER}
          ### Harness Retro Proposal (`#{upgrade["lever"]}`, priority #{upgrade["priority"]})
          - **Upgrade ID:** `#{upgrade["id"]}`
          - **Triggered after merge of:** #{source}
          - **Target files:** #{targets.empty? ? "_tbd_" : targets}

          ### Brief
          #{upgrade["brief"]}

          ### Hard Stop Condition (`done_if`)
          #{upgrade["done_if"]}

          _Switch label from `agent:needs-info` to `agent:ready` if you want the harness to implement this upgrade._
        MD

      title = "[retro] #{upgrade["title"]}"
      if @github && @github.respond_to?(:create_issue)
        @github.create_issue(title: title, body: body, label: "agent:needs-info")
      else
        out, status = Open3.capture2e(
          "gh", "issue", "create",
          "--title", title,
          "--body", body,
          "--label", "agent:needs-info",
          chdir: @repo_root
        )
        raise CommandError, "gh issue create failed:\n#{out}" unless status.success?

        out.strip
      end
    end

    def read_truncated(path, max_bytes)
      return "" unless path && File.exist?(path)

      content = File.read(path)
      return content if content.bytesize <= max_bytes

      "#{content.byteslice(0, max_bytes)}\n... [TRUNCATED]"
    end

    def format_markdown_report(report, telemetry_summary:, candidates:)
      lessons_md = Array(report["lessons"]).map do |lesson|
        "- **[#{lesson["recommended_lever"]}] #{lesson["pattern"]}**: #{lesson["root_cause"]} _(Evidence: #{lesson["evidence"]})_"
      end.join("\n")

      upgrades_md = Array(report["proposed_upgrades"]).sort_by { |u| u["priority"].to_i }.map do |u|
        files = Array(u["target_files"]).map { |f| "`#{f}`" }.join(", ")
        <<~UP
            ### #{u["priority"]}. [#{u["lever"]}] #{u["title"]} (`#{u["id"]}`)
            - **Target files:** #{files.empty? ? "_tbd_" : files}
            - **Brief:** #{u["brief"]}
            - **Done if:** #{u["done_if"]}
          UP
      end.join("\n")

      evals_md = Array(report["eval_candidates"]).map do |e|
        "- **Issue ##{e["issue_number"]}**: #{e["reason"]} (Spec focus: #{e["suggested_spec_focus"]})"
      end.join("\n")

      <<~MD
          # Harness Retro Report

          - **Merged PRs analyzed:** #{candidates.size}
          - **Telemetry runs:** #{telemetry_summary[:total_runs]} (first-pass verify: #{telemetry_summary[:first_pass_verify_count]}, review disagreements: #{telemetry_summary[:review_disagreements]})
          - **PR outcomes:** clean=#{telemetry_summary[:merged_clean]}, edited=#{telemetry_summary[:merged_edited]}, abandoned=#{telemetry_summary[:abandoned]}

          ## Summary
          #{report["summary"]}

          ## Lessons Learned
          #{lessons_md.empty? ? "_None_" : lessons_md}

          ## Proposed High-Leverage Upgrades (max 3)
          #{upgrades_md.empty? ? "_None_" : upgrades_md}

          ## Held-Out Eval Candidates
          #{evals_md.empty? ? "_None_" : evals_md}
        MD
    end
  end
end
