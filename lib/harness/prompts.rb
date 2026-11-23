module Harness
  class Prompts
    def initialize(repo_root:)
      @repo_root = File.expand_path(repo_root)
    end

    def architect(brief:, done_if:, playbook_name:)
      playbook = load_playbook(playbook_name)
      rules_index = read_harness_file("rules/index.md")
      patterns = read_harness_file("rules/patterns.md")
      golden_flow = read_harness_file("rules/golden-flow.md")
      canonical = read_harness_file("rules/canonical-files.md")
      explorer_notes = "Follow the target repository instructions. Confirm file paths and commands in the checkout."

      <<~PROMPT
        You are acting as ARCHITECT in strict read-only mode. Do NOT edit any files.

        #{rules_index}

        ---

        #{patterns}

        ---

        #{golden_flow}

        ---

        #{canonical}

        ---

        ## Explorer Guidance
        #{explorer_notes}

        ---

        ## Task Brief
        #{brief.strip}

        ## Hard Stop Condition (`done_if`)
        #{done_if.strip}

        ## Playbook (`#{playbook_name}`)
        #{playbook}

        ---

        ## Deliverable
        Inspect the codebase and return a concise, concrete Markdown implementation plan containing:
        1. Name each file to change and the interface it owns.
        2. Trace the request from its entry point to the observable result.
        3. Identify existing tests, required fixtures and the verification command.
        4. List sensitive changes and expected failure behavior.
        5. Map the playbook steps to a concrete checklist.
      PROMPT
    end

    def worker(brief:, done_if:, playbook_name:, plan:, feedback: nil)
      worker_contract = read_harness_file("rules/worker.md")
      rules_index = read_harness_file("rules/index.md")
      patterns = read_harness_file("rules/patterns.md")
      golden_flow = read_harness_file("rules/golden-flow.md")
      playbook = load_playbook(playbook_name)

      sections = [
        "You are acting as WORKER. Implement the task in the worktree following the Architect plan and playbook 1:1.\n" \
        "Run targeted project checks while working. The runner executes the profile verification hook afterward.",
        worker_contract,
        rules_index,
        patterns,
        golden_flow,
        "## Task Brief\n#{brief.strip}",
        "## Hard Stop Condition (`done_if`)\n#{done_if.strip}",
        "## Playbook (`#{playbook_name}`)\n#{playbook}"
      ]

      if plan && !plan.strip.empty?
        sections << "## Architect Plan\n#{plan.strip}"
      end

      if feedback && !feedback.strip.empty?
        sections << "## Required Fixes From Previous Verification / Review\nFix EVERY item below without weakening project checks:\n\n#{feedback.strip}"
      end

      sections.join("\n\n---\n\n")
    end

    def reviewer(brief:, done_if:, plan:, changed_files:, diff:, base_branch:,
      qa_report: nil, repro_report: nil, previous_review: nil)
      rules_index = read_harness_file("rules/index.md")
      patterns = read_harness_file("rules/patterns.md")
      golden_flow = read_harness_file("rules/golden-flow.md")
      reviewer_notes = "Independently review the candidate against its acceptance condition and the supplied project rules."
      files_list = changed_files.empty? ? "- (none)" : changed_files.map { |path| "- `#{path}`" }.join("\n")
      qa_section = if qa_report
        "\n#{Qa.format_pr_section(qa_report, repro_report: repro_report)}\n"
      else
        ""
      end
      followup_section = format_followup_review_scope(previous_review)

      <<~PROMPT
        #{reviewer_notes}

        ---

        #{rules_index}

        ---

        #{patterns}

        ---

        #{golden_flow}

        ---

        Trace each changed flow from entry to effect. Verify that expected failures stop dependent calls, and check where validated inputs and data invariants are established.
        You already have the full changed-files list, QA evidence (if recorded), and git diff below. If you inspect files, prefer read-only file tools (`read_file`, `grep_search`, `list_dir`) and avoid shell commands.
        #{followup_section}
        ## Task Brief
        #{brief.strip}

        ## Hard Stop Condition (`done_if`)
        #{done_if.strip}

        ## Architect Plan
        #{plan && !plan.strip.empty? ? plan.strip : "_No separate architect plan was generated._"}
        #{qa_section}
        ## Changed Files (#{changed_files.size})
        #{files_list}

        ## Git Diff Against `#{base_branch}`
        ```diff
        #{diff}
        ```
      PROMPT
    end

    def arbiter(brief:, done_if:, plan:, changed_files:, diff:, base_branch:, reviewer_entries:,
      qa_report: nil, repro_report: nil, previous_review: nil)
      rules_index = read_harness_file("rules/index.md")
      patterns = read_harness_file("rules/patterns.md")
      golden_flow = read_harness_file("rules/golden-flow.md")
      files_list = changed_files.empty? ? "- (none)" : changed_files.map { |path| "- `#{path}`" }.join("\n")
      qa_section = qa_report ? "\n#{Qa.format_pr_section(qa_report, repro_report: repro_report)}\n" : ""
      followup_section = format_followup_review_scope(previous_review)

      reviews_block = reviewer_entries.map do |entry|
        "### Reviewer: `#{entry[:label]}`\n```json\n#{JSON.pretty_generate(entry[:review])}\n```"
      end.join("\n\n")

      <<~PROMPT
        You are the INDEPENDENT ARBITER for the target project (read-only mode).
        Two independent reviewers have audited this diff. Your job is to inspect the actual diff, rules, and QA evidence,
        then adjudicate EVERY finding from both reviewers objectively so the Worker fixes real problems and ignores nitpicks or false positives.

        ## Adjudication Rules
        1. Classify every finding as one of:
           - `architecture_violation`: a concrete breach of a documented project boundary.
           - `valid_blocker`: real bug, security/data-loss risk, failing or missing coverage for `done_if`, or broken UI/QA behavior.
           - `nitpick`: stylistic preference, minor naming/namespace opinion, or low-risk polish not required by `done_if` or the project rules.
           - `false_positive`: claim contradicted by the actual diff, QA evidence, or codebase rules.
        2. Assign realistic `severity`, `probability` (likelihood of real defect), and `risk` (impact if unfixed) to each finding.
        3. Dismiss low-impact style preferences. Cite concrete evidence and the violated criterion for every blocker.
        4. Anti-goalpost-shifting on follow-up rounds: if a Follow-Up Review Scope section is present below, dismiss newly invented medium/low edge cases or secondary tooling concerns that were not part of the previous round's upheld findings into `dismissed_notes`. Uphold new findings in a follow-up round ONLY if they are newly introduced regressions, `critical`/`high` severity bugs, or genuine project architecture violations.
        5. Put ONLY upheld `architecture_violation` items in `architecture_violations` and ONLY upheld `valid_blocker` items in `blocking_issues`.
        6. Put dismissed `nitpick` and `false_positive` items in `dismissed_notes`.
        7. Set `approved: true` ONLY when `done_if_met` is true AND both `architecture_violations` and `blocking_issues` are empty.
        8. Prefer read-only file tools (`read_file`, `grep_search`, `list_dir`) if you verify any file; avoid unnecessary shell commands.

        ---

        #{rules_index}

        ---

        #{patterns}

        ---

        #{golden_flow}

        ---
        #{followup_section}
        ## Task Brief
        #{brief.strip}

        ## Hard Stop Condition (`done_if`)
        #{done_if.strip}

        ## Architect Plan
        #{plan && !plan.strip.empty? ? plan.strip : "_No separate architect plan was generated._"}
        #{qa_section}
        ## Reviewer Reports To Adjudicate
        #{reviews_block}

        ## Changed Files (#{changed_files.size})
        #{files_list}

        ## Git Diff Against `#{base_branch}`
        ```diff
        #{diff}
        ```
      PROMPT
    end

    def format_review_feedback(review)
      lines = [ "Reviewer verdict: #{review["summary"]}" ]

      unless review["done_if_met"]
        lines << "\n### Hard Stop Condition (`done_if`) Not Met"
        lines << "- Address missing requirements or missing test/verification evidence."
      end

      violations = Array(review["architecture_violations"])
      unless violations.empty?
        lines << "\n### Architecture Violations (UPHELD BY ARBITER - CRITICAL)"
        violations.each do |violation|
          src = violation["source_reviewer"] || Array(violation["reviewers"]).join(", ")
          meta = [ violation["severity"], violation["risk"] ? "risk=#{violation["risk"]}" : nil, src.empty? ? nil : "by #{src}" ].compact.join(", ")
          tag = meta.empty? ? "" : " (#{meta})"
          lines << "- `#{violation["file"]}` [#{violation["rule"]}]#{tag}: #{violation["explanation"]}"
        end
      end

      blockers = Array(review["blocking_issues"])
      unless blockers.empty?
        lines << "\n### Blocking Issues (UPHELD BY ARBITER)"
        blockers.each do |issue|
          src = issue["source_reviewer"] || Array(issue["reviewers"]).join(", ")
          meta = [ issue["severity"], issue["probability"] ? "prob=#{issue["probability"]}" : nil, issue["risk"] ? "risk=#{issue["risk"]}" : nil, src.empty? ? nil : "by #{src}" ].compact.join(", ")
          tag = meta.empty? ? "" : " (#{meta})"
          lines << "- `#{issue["file"]}`#{tag}: #{issue["issue"]} (Fix hint: #{issue["fix_hint"]})"
        end
      end

      lines.join("\n")
    end

    def load_playbook(name)
      Harness::Paths.task!(name)
      path = File.join(Harness::Paths.profile(@repo_root), "playbooks", "#{name}.md")
      raise Error, "Unknown playbook '#{name}'. Expected file at #{path}" unless File.exist?(path)

      File.read(path).strip
    end

    private
    def format_followup_review_scope(previous_review)
      return "" unless previous_review.is_a?(Hash)

      violations = Array(previous_review["architecture_violations"])
      blockers = Array(previous_review["blocking_issues"])
      return "" if violations.empty? && blockers.empty?

      items = []
      violations.each do |v|
        items << "- [architecture_violation] `#{v["file"]}` [#{v["rule"]}]: #{v["explanation"]}"
      end
      blockers.each do |b|
        items << "- [blocking_issue] `#{b["file"]}`: #{b["issue"]}"
      end

      <<~SCOPE

          ## Follow-Up Review Scope (Anti-Goalpost-Shifting)
          This is a follow-up review after the Worker addressed the previous round's upheld findings:
          #{items.join("\n")}

          STRICT FOLLOW-UP RULES:
          1. Primary check: verify whether EVERY previously upheld item above has been resolved cleanly.
          2. Secondary check: flag ONLY newly introduced regressions, `critical`/`high` severity bugs, or genuine project architecture violations introduced by the fix.
          3. Do NOT shift goalposts by inventing brand-new medium/low edge cases, optional refactors, or secondary tooling nuances that were not flagged in the prior round. Record any newly noticed non-critical observation in `non_blocking_notes`, NOT `blocking_issues`.
        SCOPE
    end

    def read_harness_file(relative_path)
      path = File.join(Harness::Paths.profile(@repo_root), relative_path)
      raise Error, "Missing harness file: #{path}" unless File.exist?(path)

      File.read(path).strip
    end

  end
end
