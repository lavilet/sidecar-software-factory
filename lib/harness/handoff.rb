require "open3"

module Harness
  class Handoff
    def initialize(config:, workspace:, logger:)
      @config = config
      @workspace = workspace
      @logger = logger
    end

    def call(plan:, review:, qa_report: nil, repro_report: nil)
      protected_hits = @workspace.protected_files_touched
      changed = @workspace.changed_files
      pr_body_path = @workspace.artifact_path("pr-body.md")

      File.write(pr_body_path, build_pr_body(
        plan: plan,
        review: review,
        changed_files: changed,
        protected_hits: protected_hits,
        qa_report: qa_report,
        repro_report: repro_report
      ))
      @logger.info("HANDOFF", "Wrote PR summary to #{pr_body_path}")

      if @config.dry_run || !(@config.open_pr || @config.push_only)
        @logger.info("HANDOFF", "Local-only mode (--pr not set). Worktree ready at #{@workspace.worktree_dir}")
        return nil
      end

      commit_prefix = @config.push_only ? "fix" : "harness"
      commit_title = "#{commit_prefix}(#{@config.task_id}): #{@config.brief.lines.first.to_s.strip[0, 65]}"
      @workspace.commit_and_push!(commit_title)

      if @config.push_only
        @logger.info("HANDOFF", "Pushed update to existing branch #{@workspace.branch}")
        attach_qa_videos_to_pr!(@workspace.branch, qa_report: qa_report, repro_report: repro_report) if @config.upload_evidence
        return nil
      end

      pr_title = "[harness/#{@config.playbook}] #{@config.brief.lines.first.to_s.strip[0, 70]}"
      out, status = Open3.capture2e(
        "gh", "pr", "create",
        "--draft",
        "--base", @config.base_branch,
        "--title", pr_title,
        "--body-file", pr_body_path,
        chdir: @workspace.worktree_dir
      )
      raise CommandError, "gh pr create failed:\n#{out}" unless status.success?

      pr_url = out.strip
      @logger.info("HANDOFF", "Opened Draft PR: #{pr_url}")
      attach_qa_videos_to_pr!(pr_url, qa_report: qa_report, repro_report: repro_report) if @config.upload_evidence
      pr_url
    end

    private
    # Use native attachments when the installed gh supports the option.
    # as native GitHub user-attachments so inline <video> players work on private repos.
    def attach_qa_videos_to_pr!(pr_ref, qa_report:, repro_report:)
      videos = collect_local_videos(repro_report: repro_report, qa_report: qa_report)
      return if videos.empty?

      help_out, help_st = Open3.capture2e("gh", "pr", "edit", "--help")
      return unless help_st.success? && help_out.include?("--attach")

      videos.each do |entry|
        attach_out, attach_st = Open3.capture2e(
          "gh", "pr", "edit", pr_ref.to_s, "--attach", entry[:path],
          chdir: @workspace.worktree_dir
        )
        if attach_st.success?
          @logger.info("HANDOFF", "Attached native GitHub video player (#{entry[:label]}): #{File.basename(entry[:path])}")
        else
          @logger.info("HANDOFF", "Native gh --attach skipped for #{File.basename(entry[:path])}: #{attach_out.strip}")
        end
      end
    end

    def collect_local_videos(repro_report:, qa_report:)
      entries = []
      [ [ "before", repro_report ], [ "after", qa_report ] ].each do |prefix, report|
        next unless report.is_a?(Hash)

        Array(report["viewports"]).each do |vp|
          path = vp["video_path"]
          next unless path && File.exist?(path)

          entries << { label: "#{prefix}:#{vp["viewport"]}", path: path }
        end
      end
      entries
    end
    def build_pr_body(plan:, review:, changed_files:, protected_hits:, qa_report: nil, repro_report: nil)
      warnings = []
      if protected_hits.any?
        warnings << <<~WARN.chomp
            > [!WARNING]
            > **Human-Gate:** Protected paths touched: #{protected_hits.map { |path| "`#{path}`" }.join(", ")}
          WARN
      end

      if review && review["escalated_with_warnings"] == true
        warnings << build_arbitrage_warning_callout(review)
      end

      warning_block = warnings.empty? ? "" : "#{warnings.join("\n\n")}\n\n"

      review_status_label = review && review["escalated_with_warnings"] == true ? "APPROVED WITH WARNINGS (Human Review Requested)" : "APPROVED"
      review_line = if review
        verdicts = Array(review["verdicts"])
        if verdicts.size > 1
          breakdown = verdicts.map do |verdict|
            "  - `#{verdict["reviewer"]}`: **#{verdict["approved"] ? "APPROVED" : "REJECTED"}** - #{verdict["summary"]}"
          end.join("\n")
          arbiter_note = review["arbiter"] ? "\n  - **Arbiter (`#{review["arbiter"]}`):** #{review["summary"]}" : ""
          "- Arbitrage Review (#{verdicts.size} independent reviewers): **#{review_status_label}**\n#{breakdown}#{arbiter_note}"
        else
          "- Independent Reviewer (`read-only`, fresh context): **#{review_status_label}** - #{review["summary"]}"
        end
      else
        "- Independent Reviewer: **SKIPPED**"
      end

      files_block = if changed_files.empty?
        "_No files changed._"
      else
        changed_files.map { |path| "- `#{path}`" }.join("\n")
      end

      plan_block = if plan && !plan.strip.empty?
        <<~PLAN
            <details>
            <summary>Architect Plan</summary>

            #{plan.strip}

            </details>
          PLAN
      else
        ""
      end

      qa_block = qa_report ? "\n#{Qa.format_pr_section(qa_report, repro_report: repro_report)}\n" : ""

      <<~MD
          #{warning_block}## Task
          #{@config.brief.strip}
          #{issue_link}

          **Playbook:** `#{@config.playbook}`
          **Hard stop condition (`done_if`):** #{@config.done_if.strip}

          ## Verification
          - `factory verify`: **PASSED**
          #{review_line}
          #{qa_block}
          ## Changed Files (#{changed_files.size})
          #{files_block}

          #{plan_block}
        MD
    end

    def issue_link
      match = @config.brief.match(/\AGitHub Issue #(\d+):/)
      match && @config.task_id == "gh-#{match[1]}" ? "\nCloses ##{match[1]}\n" : ""
    end

    def build_arbitrage_warning_callout(review)
      lines = [
        "> [!WARNING]",
        "> **Arbitrage Review Notes (Human Review Requested):** All deterministic checks passed with zero architecture violations and at least one reviewer approved, so this Draft PR was opened with residual medium/low notes for human judgment:"
      ]
      Array(review["blocking_issues"]).each do |issue|
        meta = [ issue["severity"], issue["risk"] ? "risk=#{issue["risk"]}" : nil ].compact.join(", ")
        tag = meta.empty? ? "" : " (#{meta})"
        hint = issue["fix_hint"].to_s.strip
        hint_suffix = hint.empty? ? "" : " Fix hint: #{hint}"
        lines << "> - `#{issue["file"]}`#{tag}: #{issue["issue"]}#{hint_suffix}"
      end
      lines.join("\n")
    end
  end
end
