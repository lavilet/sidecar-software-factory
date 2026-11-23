require "json"

module Harness
  class Router
    CONTRACT_MARKER = "<!-- HARNESS_CONTRACT -->"

    def initialize(repo_root:, backend:, model: nil, reasoning_effort: nil, logger:)
      @repo_root = File.expand_path(repo_root)
      @backend = backend
      @model = model
      @reasoning_effort = reasoning_effort
      @logger = logger
    end

    def triage(issue:, output_file:, parent_context: nil)
      schema_path = File.join(Harness::Paths::ROOT, "schemas", "triage.json")
      prompt = build_prompt(issue, parent_context: parent_context)

      result = @backend.run(
        stage: "ROUTER[##{issue["number"]}]",
        role: "router",
        worktree_dir: @repo_root,
        prompt: prompt,
        output_file: output_file,
        sandbox: "read-only",
        model: @model,
        reasoning_effort: @reasoning_effort,
        output_schema: schema_path
      )

      JSON.parse(result.output)
    end

    def format_comment(decision, next_label:)
      ac_lines = Array(decision["acceptance_criteria"]).map do |ac|
        "- [ ] **#{ac["id"]}** (`#{ac["verification_method"]}`): #{ac["criterion"]}"
      end
      ac_block = ac_lines.empty? ? "_To be finalized once blocking questions are answered._" : ac_lines.join("\n")

      questions = Array(decision["missing_questions"])
      questions_block = if questions.empty?
        ""
      else
        q_lines = questions.map { |q| "- #{q}" }.join("\n")
        "\n### Blocking Questions\n#{q_lines}\n\nReply in a comment and restore `agent:triage` to re-run triage.\n"
      end

      layers = Array(decision["affected_layers"]).map { |layer| "`#{layer}`" }.join(", ")
      next_hint = if next_label == "agent:needs-info" && questions.empty?
        "\nReview the Acceptance Criteria above and switch the label to `agent:ready` to start execution.\n"
      else
        ""
      end

      <<~MD
        #{CONTRACT_MARKER}
        ### Harness Router Analysis
        - **Kind:** `#{decision["kind"]}` | **Playbook:** `#{decision["playbook"]}` | **Risk:** `#{decision["risk_level"]}`
        - **Affected layers:** #{layers.empty? ? "_none_" : layers}
        - **Browser QA Demo:** `#{decision["needs_qa_demo"] ? "yes" : "no"}` (#{decision["qa_reason"]})
        - **Hard stop condition (`done_if`):** #{decision["done_if"]}
        - **Rationale:** #{decision["rationale"]}

        ### Acceptance Criteria
        #{ac_block}
        #{questions_block}#{next_hint}
      MD
    end

    private
    def build_prompt(issue, parent_context: nil)
      rules_index = File.read(File.join(Harness::Paths.profile(@repo_root), "rules", "index.md")).strip
      canonical = File.read(File.join(Harness::Paths.profile(@repo_root), "rules", "canonical-files.md")).strip
      comments = Array(issue["comments"]).map do |comment|
        author = comment.dig("author", "login") || comment.dig("user", "login") || "unknown"
        "@#{author}: #{comment["body"]}"
      end.join("\n\n")
      parent_block = parent_context && !parent_context.strip.empty? ? "\n#{parent_context.strip}\n\n---\n" : ""

      <<~PROMPT
          You are the TASK ROUTER for the target project (read-only mode). Do NOT edit any files.
          Inspect the existing codebase before classifying so Acceptance Criteria match real files, domains, and tests.

          #{rules_index}

          ---

          #{canonical}

          ---
          #{parent_block}
          ## GitHub Issue ##{issue["number"]}: #{issue["title"]}
          #{issue["body"]}

          ## Thread Comments
          #{comments.empty? ? "_None_" : comments}

          ---

          ## Instructions
          1. Classify `kind` and pick `playbook` (`bugfix` or `feature`).
          2. Set `ready_to_execute: false` and list concise `missing_questions` if business rules, UX expectations, or bug repro are ambiguous.
          3. Otherwise set `ready_to_execute: true` and write testable, concrete `acceptance_criteria` (`AC-1`, `AC-2`, ...) plus a verifiable `done_if`.
          4. Set `risk_level: "high"` if the change touches migrations, authentication, sessions, payments, or deploy config.
          5. Set `needs_qa_demo: true` whenever the task changes user-visible UI, browser navigation, forms, layout, or reproduces a user-facing bug; set `false` for pure backend/refactor/tooling changes, and explain concisely in `qa_reason`.
        PROMPT
    end
  end
end
