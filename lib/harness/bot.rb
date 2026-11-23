require "json"
require "time"

module Harness
  # External loop bot for GitHub Issues and PR Review Babysitter.
  # Label state machine:
  #   agent:triage -> agent:needs-info | agent:ready -> agent:in-progress -> agent:review | agent:blocked -> agent:merged
  class Bot
    BOT_MARKER = "<!-- HARNESS_BOT -->"
    HUMAN_CLEAN_MAX_LINES = 10
    SINGLE_COMMENT_DEBOUNCE_SEC = 60

    def initialize(repo_root:, github:, store:, router:, logger:, telemetry:, runner_factory:,
      base_branch: "main", auto_approve: false, open_pr: true, dry_run: false, max_concurrency: 1,
      on_merge: nil, force_qa: false, upload_evidence: false)
      @repo_root = File.expand_path(repo_root)
      @github = github
      @store = store
      @router = router
      @logger = logger
      @telemetry = telemetry
      @runner_factory = runner_factory
      @base_branch = base_branch
      @auto_approve = auto_approve
      @open_pr = open_pr
      @dry_run = dry_run
      @max_concurrency = max_concurrency
      @on_merge = on_merge
      @force_qa = force_qa
      @upload_evidence = upload_evidence
    end

    def tick!
      unblock_waiting_deps
      process_triage_queue
      dispatch_ready_queue
      babysit_open_prs
    end

    # Called once at bot startup: moves any orphaned `agent:in-progress` issues left behind
    # by a killed/restarted bot process back to `agent:ready` so Runner resumes from checkpoint.
    def recover_orphaned_in_progress!
      @github.issues_with_label("agent:in-progress").each do |issue|
        next if epic_issue?(issue)

        num = issue["number"]
        @logger.info("BOT", "Recovering orphaned agent:in-progress issue ##{num} -> moving to agent:ready (will resume from checkpoint)")
        next if @dry_run

        @github.transition_label(num, remove: "agent:in-progress", add: "agent:ready")
        existing = @store.find(num) || {}
        @store.save(num, existing.merge("state" => "agent:ready"))
      end
    end

    private
    def epic_issue?(issue)
      Array(issue["labels"]).any? { |l| (l.is_a?(Hash) ? l["name"] : l.to_s) == "agent:epic" }
    end

    def open_dependencies(depends_on)
      Array(depends_on).select do |dep_num|
        dep = @github.issue_view(dep_num)
        dep["state"].to_s.upcase != "CLOSED"
      end
    end

    def fetch_parent_context(parent_num)
      return nil unless parent_num

      epic = @github.issue_view(parent_num)
      body = epic["body"].to_s.strip
      body = "#{body.byteslice(0, 6_000)}\n... [EPIC BODY TRUNCATED]" if body.bytesize > 6_000

      <<~CTX
          ## Parent Epic Context (##{parent_num}: #{epic["title"]})
          #{body}
        CTX
    end

    def unblock_waiting_deps
      @github.issues_with_label("agent:waiting-deps").each do |issue|
        next if epic_issue?(issue)

        num = issue["number"]
        meta = EpicParser.parse(issue["body"])
        still_open = open_dependencies(meta.depends_on)
        next unless still_open.empty?

        @logger.info("BOT", "All dependencies closed for issue ##{num} -> moving agent:waiting-deps to agent:ready")
        next if @dry_run

        @github.transition_label(num, remove: "agent:waiting-deps", add: "agent:ready")
        existing = @store.find(num) || {}
        @store.save(num, existing.merge("state" => "agent:ready"))
      end
    end

    def process_triage_queue
      @github.issues_with_label("agent:triage").each do |issue|
        next if epic_issue?(issue)

        num = issue["number"]
        meta = EpicParser.parse(issue["body"])
        @logger.info("BOT", "Triaging issue ##{num}: #{issue["title"]} (parent=#{meta.parent_issue || "none"} deps=#{meta.depends_on.inspect} pilot=#{meta.pilot})")

        if @dry_run
          @logger.info("BOT", "[dry-run] Would triage issue ##{num}")
          next
        end

        parent_context = fetch_parent_context(meta.parent_issue)
        out_file = @store.artifact_path("triage-#{num}.json")
        decision = @router.triage(issue: issue, output_file: out_file, parent_context: parent_context)
        auto_ready = @auto_approve && decision["ready_to_execute"] == true && decision["risk_level"] != "high"
        next_label = auto_ready ? "agent:ready" : "agent:needs-info"

        comment = @router.format_comment(decision, next_label: next_label)
        @github.comment_issue(num, comment)
        @github.transition_label(num, remove: "agent:triage", add: next_label)

        existing = @store.find(num) || {}
        @store.save(num, existing.merge(
          "state" => next_label,
          "kind" => decision["kind"],
          "playbook" => decision["playbook"],
          "contract" => decision,
          "parent_issue" => meta.parent_issue,
          "depends_on" => meta.depends_on,
          "pilot" => meta.pilot,
          "handled_review_ids" => Array(existing["handled_review_ids"]),
          "review_fix_rounds" => existing.fetch("review_fix_rounds", 0)
        ))
        @logger.info("BOT", "Issue ##{num} moved to #{next_label}")
      end
    end

    def dispatch_ready_queue
      ready_issues = @github.issues_with_label("agent:ready")
      dispatched = 0

      ready_issues.each do |issue|
        break if dispatched >= @max_concurrency
        next if epic_issue?(issue)

        num = issue["number"]
        meta = EpicParser.parse(issue["body"])
        record = @store.find(num)
        contract = record && record["contract"]
        unless contract
          @logger.info("BOT", "Skipping issue ##{num}: no triage contract found; re-label agent:triage first.")
          next
        end

        blocking_deps = open_dependencies(meta.depends_on)
        unless blocking_deps.empty?
          @logger.info("BOT", "Issue ##{num} waiting on open dependencies: #{blocking_deps.map { |d| "##{d}" }.join(", ")}")
          unless @dry_run
            @github.transition_label(num, remove: "agent:ready", add: "agent:waiting-deps")
            @github.comment_issue(
              num,
              "#{BOT_MARKER}\nWaiting for open dependencies to close before starting: #{blocking_deps.map { |d| "##{d}" }.join(", ")}.\n" \
              "The bot will automatically move this issue back to `agent:ready` once they are closed."
            )
            @store.save(num, record.merge(
              "state" => "agent:waiting-deps",
              "parent_issue" => meta.parent_issue,
              "depends_on" => meta.depends_on,
              "pilot" => meta.pilot
            ))
          end
          next
        end

        task_id = "gh-#{num}"
        if @dry_run
          @logger.info("BOT", "[dry-run] Would dispatch issue ##{num} as #{task_id}")
          next
        end

        dispatched += 1
        @github.transition_label(num, remove: "agent:ready", add: "agent:in-progress")
        @store.save(num, record.merge(
          "state" => "agent:in-progress",
          "task_id" => task_id,
          "parent_issue" => meta.parent_issue,
          "depends_on" => meta.depends_on,
          "pilot" => meta.pilot
        ))

        parent_context = fetch_parent_context(meta.parent_issue)
        brief = build_issue_brief(issue, contract, parent_context: parent_context)
        should_run_qa = @force_qa || contract["needs_qa_demo"] == true
        begin
          result = @runner_factory.call(
            task_id: task_id,
            playbook: contract["playbook"],
            brief: brief,
            done_if: contract["done_if"],
            base_branch: @base_branch,
            open_pr: @open_pr,
            push_only: false,
            skip_architect: false,
            run_qa: should_run_qa,
            upload_evidence: should_run_qa && @upload_evidence
          )

          pr_url = result[:pr_url]
          pr_number = extract_pr_number(pr_url)
          head_sha = result[:head_sha]

          @store.save(num, record.merge(
            "state" => "agent:review",
            "task_id" => task_id,
            "branch" => "harness/#{task_id}",
            "pr_url" => pr_url,
            "pr_number" => pr_number,
            "agent_head_sha" => head_sha,
            "parent_issue" => meta.parent_issue,
            "depends_on" => meta.depends_on,
            "pilot" => meta.pilot
          ))
          @github.transition_label(num, remove: "agent:in-progress", add: "agent:review")
          escalated_note = if result[:review_escalated]
            "\n\n> [!WARNING]\n> Arbitrage Review escalated residual medium/low notes to the Draft PR body for human review (all deterministic checks passed with zero architecture violations)."
          else
            ""
          end
          @github.comment_issue(
            num,
            "#{BOT_MARKER}\nDraft PR ready for review: #{pr_url || "(local-only mode)"}#{escalated_note}\n\n" \
            "Leave line comments and submit your review on the PR; the bot will pick them up automatically."
          )
          if meta.parent_issue
            pilot_tag = meta.pilot ? " [PILOT]" : ""
            @github.comment_issue(
              meta.parent_issue,
              "#{BOT_MARKER}\nChild ##{num}#{pilot_tag} opened Draft PR: #{pr_url || "(local-only)"}"
            )
          end
          @logger.info("BOT", "Issue ##{num} completed -> agent:review (#{pr_url})")
        rescue Error => error
          @store.save(num, record.merge("state" => "agent:blocked", "last_error" => error.message))
          @github.transition_label(num, remove: "agent:in-progress", add: "agent:blocked")
          @github.comment_issue(num, format_blocked_comment(task_id, error, intro: "Harness blocked on `#{task_id}`:"))
          @logger.info("BOT", "Issue ##{num} blocked: #{error.message}")
        end
      end
    end

    def babysit_open_prs
      return if @dry_run

      resync_unblocked_review_issues
      @store.all.each do |record|
        next unless record["state"] == "agent:review" && record["pr_number"]

        num = record["issue_number"]
        pr_num = record["pr_number"]
        pr = @github.pr_view(pr_num)

        case pr["state"].to_s.upcase
        when "MERGED"
          handle_merged_pr(record, pr)
        when "CLOSED"
          handle_abandoned_pr(record, pr)
        when "OPEN"
          handle_open_pr_reviews(record, pr)
        end
      end
    end

    def resync_unblocked_review_issues
      @github.issues_with_label("agent:review").each do |issue|
        num = issue["number"]
        record = @store.find(num)
        next unless record && record["pr_number"] && record["state"] == "agent:blocked"

        @logger.info("BOT", "Issue ##{num} restored to agent:review on GitHub -> resuming PR ##{record["pr_number"]} babysitting")
        @store.save(num, record.merge("state" => "agent:review"))
      end
    end

    def handle_open_pr_reviews(record, pr)
      num = record["issue_number"]
      pr_num = record["pr_number"]
      handled_ids = Array(record["handled_review_ids"]).map(&:to_s)
      reviews = Array(pr["reviews"])
      inline_comments = @github.pr_review_comments(pr_num)

      pending_reviews = reviews.select do |review|
        review_id = review["id"].to_s
        node_id = review["node_id"].to_s
        state = review["state"].to_s.upcase
        body = review["body"].to_s
        next false if review_id.empty? || handled_ids.include?(review_id) || (!node_id.empty? && handled_ids.include?(node_id))
        next false if body.include?(BOT_MARKER)
        next false unless %w[ CHANGES_REQUESTED COMMENTED ].include?(state)

        has_inline = inline_comments.any? do |c|
          cid = c["pull_request_review_id"].to_s
          cid == review_id || (!node_id.empty? && cid == node_id)
        end
        state == "CHANGES_REQUESTED" || !body.strip.empty? || has_inline
      end

      return if pending_reviews.empty?

      # Wait briefly if the human is posting individual inline comments one by one
      # (empty-body COMMENTED reviews) so all comments get batched into one babysit-pr run.
      if only_fresh_single_comments?(pending_reviews)
        @logger.info("BOT", "PR ##{pr_num} has #{pending_reviews.size} recent single inline comment(s); waiting #{SINGLE_COMMENT_DEBOUNCE_SEC}s for review batch to settle")
        return
      end

      @logger.info("BOT", "PR ##{pr_num} (issue ##{num}) has #{pending_reviews.size} new submitted review(s)")
      return if @dry_run

      @github.transition_label(num, remove: "agent:review", add: "agent:in-progress")
      @store.save(num, record.merge("state" => "agent:in-progress"))

      review_brief = build_review_fix_brief(record, pr, pending_reviews, inline_comments)
      done_if = "All submitted GitHub PR ##{pr_num} review comments are addressed, specs pass, and factory verify is green."
      should_run_qa = @force_qa || record.dig("contract", "needs_qa_demo") == true

      begin
        result = @runner_factory.call(
          task_id: record["task_id"],
          playbook: "babysit-pr",
          brief: review_brief,
          done_if: done_if,
          base_branch: pr["baseRefName"] || @base_branch,
          open_pr: false,
          push_only: @open_pr,
          skip_architect: true,
          run_qa: should_run_qa,
          upload_evidence: should_run_qa && @upload_evidence
        )

        new_handled = (handled_ids + pending_reviews.map { |r| r["id"].to_s }).uniq
        rounds = record.fetch("review_fix_rounds", 0) + 1
        new_sha = result[:head_sha] || record["agent_head_sha"]

        @store.save(num, record.merge(
          "state" => "agent:review",
          "agent_head_sha" => new_sha,
          "handled_review_ids" => new_handled,
          "review_fix_rounds" => rounds
        ))
        @github.transition_label(num, remove: "agent:in-progress", add: "agent:review")
        review_verdict_label = result[:review_escalated] ? "APPROVED WITH WARNINGS (see PR body)" : "APPROVED"
        @github.comment_pr(
          pr_num,
          "#{BOT_MARKER}\nAddressed #{pending_reviews.size} submitted review(s) (round #{rounds}) " \
          "and pushed commit `#{new_sha.to_s[0, 10]}`.\n" \
          "- `factory verify`: **PASSED**\n" \
          "- Arbitrage Review: **#{review_verdict_label}**"
        )
        @logger.info("BOT", "PR ##{pr_num} updated and returned to agent:review")
      rescue Error => error
        @store.save(num, record.merge("state" => "agent:blocked", "last_error" => error.message))
        @github.transition_label(num, remove: "agent:in-progress", add: "agent:blocked")
        @github.comment_pr(pr_num, format_blocked_comment(record["task_id"], error, intro: "Could not resolve PR review automatically:"))
        @logger.info("BOT", "PR ##{pr_num} blocked during review fix: #{error.message}")
      end
    end

    def handle_merged_pr(record, pr)
      num = record["issue_number"]
      pr_num = record["pr_number"]
      merge_sha = pr.dig("mergeCommit", "oid")
      agent_sha = record["agent_head_sha"]

      diff_info = @github.human_diff(agent_sha, merge_sha)
      outcome = diff_info[:lines] <= HUMAN_CLEAN_MAX_LINES ? "merged_clean" : "merged_edited"

      human_diff_path = @store.artifact_path("issue-#{num}-human.diff")
      File.write(human_diff_path, diff_info[:diff]) unless diff_info[:diff].empty?

      reviews_snapshot_path = @store.artifact_path("issue-#{num}-reviews.json")
      File.write(reviews_snapshot_path, JSON.pretty_generate(
        pr_number: pr_num,
        issue_number: num,
        outcome: outcome,
        human_diff_lines: diff_info[:lines],
        reviews: Array(pr["reviews"]),
        inline_comments: @github.pr_review_comments(pr_num)
      ))

      @store.save(num, record.merge(
        "state" => "merged",
        "outcome" => outcome,
        "merge_sha" => merge_sha,
        "human_diff_lines" => diff_info[:lines],
        "human_diff_path" => diff_info[:diff].empty? ? nil : human_diff_path,
        "reviews_snapshot_path" => reviews_snapshot_path,
        "retro_processed" => false
      ))

      @github.transition_label(num, remove: "agent:review", add: "agent:merged") unless @dry_run
      @telemetry.record(
        event: "pr_outcome",
        issue_number: num,
        pr_number: pr_num,
        task_id: record["task_id"],
        kind: record["kind"],
        playbook: record["playbook"],
        outcome: outcome,
        human_diff_lines: diff_info[:lines],
        review_fix_rounds: record.fetch("review_fix_rounds", 0),
        agent_head_sha: agent_sha,
        merge_sha: merge_sha,
        recorded_at: Time.now.utc.iso8601
      )
      @logger.info("BOT", "PR ##{pr_num} merged -> outcome=#{outcome} human_diff_lines=#{diff_info[:lines]} (queued for retro)")
      if record["parent_issue"] && !@dry_run
        pilot_note = if record["pilot"]
          " **[PILOT COMPLETE]** Running post-merge Retro to capture canonical patterns / verification improvements before dependent children run."
        else
          ""
        end
        @github.comment_issue(
          record["parent_issue"],
          "#{BOT_MARKER}\nChild ##{num} merged (PR ##{pr_num}, `#{outcome}`, human_diff_lines=#{diff_info[:lines]}).#{pilot_note}"
        )
      end
      @on_merge&.call(num, pilot: record["pilot"] == true) unless @dry_run
    end

    def handle_abandoned_pr(record, pr)
      num = record["issue_number"]
      pr_num = record["pr_number"]
      @store.save(num, record.merge("state" => "abandoned", "outcome" => "abandoned"))
      @telemetry.record(
        event: "pr_outcome",
        issue_number: num,
        pr_number: pr_num,
        task_id: record["task_id"],
        kind: record["kind"],
        playbook: record["playbook"],
        outcome: "abandoned",
        review_fix_rounds: record.fetch("review_fix_rounds", 0),
        recorded_at: Time.now.utc.iso8601
      )
      @logger.info("BOT", "PR ##{pr_num} closed without merge -> abandoned")
    end

    def build_issue_brief(issue, contract, parent_context: nil)
      ac_lines = Array(contract["acceptance_criteria"]).map do |ac|
        "- #{ac["id"]} [#{ac["verification_method"]}]: #{ac["criterion"]}"
      end.join("\n")

      parent_block = parent_context && !parent_context.strip.empty? ? "\n#{parent_context.strip}\n" : ""

      <<~BRIEF
          GitHub Issue ##{issue["number"]}: #{issue["title"]}

          #{issue["body"]}
          #{parent_block}
          ## Approved Acceptance Criteria (REQUIRED)
          #{ac_lines}
        BRIEF
    end

    def build_review_fix_brief(record, pr, pending_reviews, inline_comments)
      sections = [ "Address submitted review feedback on PR ##{pr["number"]} (Issue ##{record["issue_number"]})." ]

      pending_reviews.each do |review|
        review_id = review["id"].to_s
        node_id = review["node_id"].to_s
        author = review.dig("author", "login") || review.dig("user", "login") || "reviewer"
        sections << "### Review #{review_id} by @#{author} (#{review["state"]})\n#{review["body"].to_s.strip}"

        matching_inline = inline_comments.select do |c|
          cid = c["pull_request_review_id"].to_s
          cid == review_id || (!node_id.empty? && cid == node_id)
        end
        unless matching_inline.empty?
          lines = matching_inline.map do |comment|
            line_no = comment["line"] || comment["original_line"] || "?"
            "- `#{comment["path"]}:#{line_no}`: #{comment["body"].to_s.strip}"
          end
          sections << "#### Inline Comments\n#{lines.join("\n")}"
        end
      end

      sections.join("\n\n")
    end

    def format_blocked_comment(_task_id, error, intro:)
      lines = [ BOT_MARKER, intro, "```", error.message, "```" ]

      if error.is_a?(ReviewError) && error.review.is_a?(Hash)
        review = error.review
        lines << ""
        lines << "### Arbiter Verdict"
        lines << review["summary"].to_s unless review["summary"].to_s.strip.empty?

        verdicts = Array(review["verdicts"])
        unless verdicts.empty?
          lines << ""
          lines << "**Reviewers:**"
          verdicts.each do |v|
            tag = v["approved"] ? "APPROVED" : "REJECTED"
            lines << "- `#{v["reviewer"]}`: **#{tag}** - #{v["summary"]}"
          end
        end

        violations = Array(review["architecture_violations"])
        unless violations.empty?
          lines << ""
          lines << "**Upheld Architecture Violations:**"
          violations.each do |v|
            meta = [ v["severity"], v["risk"] ? "risk=#{v["risk"]}" : nil ].compact.join(", ")
            tag = meta.empty? ? "" : " (#{meta})"
            lines << "- `#{v["file"]}` [#{v["rule"]}]#{tag}: #{v["explanation"]}"
          end
        end

        blockers = Array(review["blocking_issues"])
        unless blockers.empty?
          lines << ""
          lines << "**Upheld Blocking Issues:**"
          blockers.each do |b|
            meta = [ b["severity"], b["risk"] ? "risk=#{b["risk"]}" : nil ].compact.join(", ")
            tag = meta.empty? ? "" : " (#{meta})"
            hint = b["fix_hint"].to_s.strip
            hint_part = hint.empty? ? "" : "\n  - _Fix hint:_ #{hint}"
            lines << "- `#{b["file"]}`#{tag}: #{b["issue"]}#{hint_part}"
          end
        end
      elsif error.is_a?(VerificationError) && !error.output.to_s.strip.empty?
        tail = error.output.to_s.lines.last(30).join.strip
        lines << ""
        lines << "<details>"
        lines << "<summary>Verification output tail (category=#{error.category}, exit=#{error.exit_code})</summary>"
        lines << ""
        lines << "```"
        lines << tail
        lines << "```"
        lines << "</details>"
      end

      lines.join("\n")
    end

    def only_fresh_single_comments?(pending_reviews)
      return false unless pending_reviews.all? { |r| r["state"].to_s.upcase == "COMMENTED" && r["body"].to_s.strip.empty? }

      newest_ts = pending_reviews.filter_map do |r|
        raw = r["submitted_at"] || r["submittedAt"]
        next if raw.to_s.strip.empty?

        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end.max

      return false unless newest_ts

      (Time.now.utc - newest_ts) < SINGLE_COMMENT_DEBOUNCE_SEC
    end

    def extract_pr_number(pr_url)
      match = pr_url.to_s.match(%r{/pull/(\d+)})
      match ? match[1].to_i : nil
    end
  end
end
