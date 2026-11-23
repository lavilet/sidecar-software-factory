require "json"

module Harness
  # Runs 2+ independent read-only reviewers in parallel, then invokes an independent LLM Arbiter
  # whenever any reviewer flags an issue or disagrees, adjudicating valid blockers vs nitpicks/false positives
  # with severity, probability, and risk ratings.
  class ArbitrageReviewer
    def initialize(reviewers:, repo_root:, workspace:, logger:, prompts:, arbiter: nil, on_stage_result: nil)
      @reviewers = reviewers
      @arbiter = arbiter
      @repo_root = repo_root
      @workspace = workspace
      @logger = logger
      @prompts = prompts
      @on_stage_result = on_stage_result
    end

    def call(brief:, done_if:, plan:, base_branch:, round:, qa_report: nil, repro_report: nil, previous_review: nil)
      schema_path = File.join(Harness::Paths::ROOT, "schemas", "review.json")
      changed = @workspace.changed_files
      diff = @workspace.full_diff
      prompt = @prompts.reviewer(
        brief: brief,
        done_if: done_if,
        plan: plan,
        changed_files: changed,
        diff: diff,
        base_branch: base_branch,
        qa_report: qa_report,
        repro_report: repro_report,
        previous_review: previous_review
      )
      File.write(@workspace.artifact_path("reviewer-prompt-r#{round}.md"), prompt)

      results = run_reviewers_in_parallel(prompt: prompt, schema_path: schema_path, round: round)
      merged = if fast_path_unanimous_approve?(results)
        build_unanimous_verdict(results)
      elsif @arbiter
        run_arbiter_stage(
          entries: results,
          brief: brief,
          done_if: done_if,
          plan: plan,
          changed: changed,
          diff: diff,
          base_branch: base_branch,
          round: round,
          qa_report: qa_report,
          repro_report: repro_report,
          previous_review: previous_review
        )
      else
        conservative_merge(results)
      end

      File.write(@workspace.artifact_path("review-r#{round}-arbitrage.json"), JSON.pretty_generate(merged))
      merged
    end

    private
    def run_reviewers_in_parallel(prompt:, schema_path:, round:)
      threads = @reviewers.each_with_index.map do |entry, idx|
        Thread.new do
          label = entry.fetch(:label)
          backend = entry.fetch(:backend)
          model = entry[:model]
          safe_label = label.gsub(/[^a-zA-Z0-9_-]+/, "-")
          review_file = @workspace.artifact_path("review-r#{round}-#{idx + 1}-#{safe_label}.json")

          stage_name = "REVIEWER[r#{round}:#{label}]"
          raw = backend.run(
            stage: stage_name,
            role: "reviewer",
            worktree_dir: @workspace.worktree_dir,
            prompt: prompt,
            output_file: review_file,
            sandbox: "read-only",
            model: model,
            reasoning_effort: entry[:effort],
            output_schema: schema_path
          )

          @on_stage_result&.call(stage: stage_name, role: "reviewer", backend: backend.name, model: model, result: raw)
          { label: label, review: JSON.parse(raw.output) }
        end
      end

      threads.map(&:value)
    end

    def run_arbiter_stage(entries:, brief:, done_if:, plan:, changed:, diff:, base_branch:, round:,
      qa_report:, repro_report:, previous_review: nil)
      arbiter_schema = File.join(Harness::Paths::ROOT, "schemas", "arbiter.json")
      arbiter_prompt = @prompts.arbiter(
        brief: brief,
        done_if: done_if,
        plan: plan,
        changed_files: changed,
        diff: diff,
        base_branch: base_branch,
        reviewer_entries: entries,
        qa_report: qa_report,
        repro_report: repro_report,
        previous_review: previous_review
      )
      File.write(@workspace.artifact_path("arbiter-prompt-r#{round}.md"), arbiter_prompt)
      out_file = @workspace.artifact_path("arbiter-r#{round}.json")

      label = @arbiter.fetch(:label)
      backend = @arbiter.fetch(:backend)
      stage_name = "ARBITER[r#{round}:#{label}]"
      @logger.info("REVIEW", "Invoking independent Arbiter (#{label}) to adjudicate #{entries.size} reviewer report(s)")

      raw = backend.run(
        stage: stage_name,
        role: "arbiter",
        worktree_dir: @workspace.worktree_dir,
        prompt: arbiter_prompt,
        output_file: out_file,
        sandbox: "read-only",
        model: @arbiter[:model],
        reasoning_effort: @arbiter[:effort],
        output_schema: arbiter_schema
      )
      @on_stage_result&.call(stage: stage_name, role: "arbiter", backend: backend.name, model: @arbiter[:model], result: raw)

      ruling = JSON.parse(raw.output)
      verdicts = build_verdict_list(entries)
      disagreement = verdicts.map { |v| v["approved"] }.uniq.size > 1
      upheld_violations = Array(ruling["architecture_violations"])
      upheld_blockers = Array(ruling["blocking_issues"])
      final_approved = ruling["approved"] == true &&
        ruling["done_if_met"] == true &&
        upheld_violations.empty? &&
        upheld_blockers.empty?

      {
        "approved" => final_approved,
        "done_if_met" => ruling["done_if_met"] == true,
        "disagreement" => disagreement,
        "arbiter" => label,
        "summary" => "[Arbiter #{label}: #{final_approved ? "APPROVED" : "REJECTED"}] #{ruling["summary"]}",
        "verdicts" => verdicts,
        "ruled_findings" => Array(ruling["ruled_findings"]),
        "architecture_violations" => upheld_violations,
        "blocking_issues" => upheld_blockers,
        "non_blocking_notes" => Array(ruling["dismissed_notes"])
      }
    rescue CommandError, JSON::ParserError => error
      @logger.info("REVIEW", "Arbiter (#{label}) failed (#{error.message}); falling back to conservative merge of reviewer reports")
      conservative_merge(entries)
    end

    def fast_path_unanimous_approve?(entries)
      entries.all? { |entry| single_approved?(entry[:review]) }
    end

    def build_unanimous_verdict(entries)
      verdicts = build_verdict_list(entries)
      summary = verdicts.map { |v| "[#{v["reviewer"]}: APPROVED] #{v["summary"]}" }.join(" | ")
      notes = entries.flat_map do |entry|
        Array(entry[:review]["non_blocking_notes"]).map { |note| "[#{entry[:label]}] #{note}" }
      end.uniq

      {
        "approved" => true,
        "done_if_met" => true,
        "disagreement" => false,
        "arbiter" => "fast-path (unanimous)",
        "summary" => summary,
        "verdicts" => verdicts,
        "ruled_findings" => [],
        "architecture_violations" => [],
        "blocking_issues" => [],
        "non_blocking_notes" => notes
      }
    end

    def conservative_merge(entries)
      verdicts = build_verdict_list(entries)
      violations = merge_items(entries, "architecture_violations", key_fields: %w[ file rule explanation ])
      blockers = merge_items(entries, "blocking_issues", key_fields: %w[ file issue ])
      notes = entries.flat_map do |entry|
        Array(entry[:review]["non_blocking_notes"]).map { |note| "[#{entry[:label]}] #{note}" }
      end.uniq

      all_done_if = entries.all? { |entry| entry[:review]["done_if_met"] == true }
      all_approved = verdicts.all? { |verdict| verdict["approved"] } && violations.empty? && blockers.empty?
      disagreement = verdicts.map { |verdict| verdict["approved"] }.uniq.size > 1

      summary = verdicts.map do |verdict|
        tag = verdict["approved"] ? "APPROVED" : "REJECTED"
        "[#{verdict["reviewer"]}: #{tag}] #{verdict["summary"]}"
      end.join(" | ")

      {
        "approved" => all_approved,
        "done_if_met" => all_done_if,
        "disagreement" => disagreement,
        "arbiter" => "conservative-merge",
        "summary" => summary,
        "verdicts" => verdicts,
        "ruled_findings" => [],
        "architecture_violations" => violations,
        "blocking_issues" => blockers,
        "non_blocking_notes" => notes
      }
    end

    def build_verdict_list(entries)
      entries.map do |entry|
        review = entry[:review]
        {
          "reviewer" => entry[:label],
          "approved" => single_approved?(review),
          "done_if_met" => review["done_if_met"] == true,
          "summary" => review["summary"].to_s,
          "architecture_violations_count" => Array(review["architecture_violations"]).size,
          "blocking_issues_count" => Array(review["blocking_issues"]).size
        }
      end
    end

    def single_approved?(review)
      review["approved"] == true &&
        review["done_if_met"] == true &&
        Array(review["architecture_violations"]).empty? &&
        Array(review["blocking_issues"]).empty?
    end

    def merge_items(entries, field, key_fields:)
      seen = {}
      merged = []

      entries.each do |entry|
        Array(entry[:review][field]).each do |item|
          dedup_key = key_fields.map { |key| item[key].to_s.strip.downcase }
          if seen.key?(dedup_key)
            seen[dedup_key]["reviewers"] << entry[:label] unless seen[dedup_key]["reviewers"].include?(entry[:label])
          else
            enriched = item.merge("reviewers" => [ entry[:label] ])
            seen[dedup_key] = enriched
            merged << enriched
          end
        end
      end

      merged
    end
  end
end
