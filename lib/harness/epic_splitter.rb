require "fileutils"
require "json"
require "open3"

module Harness
  # Reads a Parent Epic issue and generates child issues with automatic:
  #   Parent: #<epic>
  #   Depends on: #<real-child-issue-numbers> | none
  #   Pilot: true (for the pilot slice)
  # Dry-run by default; requires explicit create: true to write to GitHub.
  class EpicSplitter
    def initialize(repo_root:, github:, backend:, model: nil, reasoning_effort: nil, logger:)
      @repo_root = File.expand_path(repo_root)
      @github = github
      @backend = backend
      @model = model
      @reasoning_effort = reasoning_effort
      @logger = logger
    end

    def plan(epic_number:)
      epic = @github.issue_view(epic_number)
      schema_path = File.join(Harness::Paths::ROOT, "schemas", "epic-split.json")
      runs_dir = File.join(Harness::Paths.profile(@repo_root), "runs", "epics")
      FileUtils.mkdir_p(runs_dir)
      out_file = File.join(runs_dir, "epic-#{epic_number}-plan.json")

      prompt = <<~PROMPT
        You are the EPIC SPLITTER for the target project (read-only mode).
        Parse the Parent Epic issue below into ordered, small child tasks matching the tasks described in the Epic.
        Rules:
        1. Give each task a short stable `key` (e.g. `parser`, `validation`, `export`).
        2. Mark ONLY the first foundational slice as `pilot: true`; all others `pilot: false`.
        3. Express task dependencies in `depends_on_keys` using earlier task `key` values (e.g. `["parser"]`), in topological order.
        4. Keep each task's `body` crisp and actionable with concrete scope, files, and acceptance checks.

        ## Parent Epic ##{epic["number"]}: #{epic["title"]}
        #{epic["body"]}
      PROMPT

      result = @backend.run(
        stage: "EPIC_SPLIT[##{epic_number}]",
        role: "router",
        worktree_dir: @repo_root,
        prompt: prompt,
        output_file: out_file,
        sandbox: "read-only",
        model: @model,
        reasoning_effort: @reasoning_effort,
        output_schema: schema_path
      )

      JSON.parse(result.output)
    end

    def create_children(split_plan:, epic_number:, pilot_only: false, initial_label: "agent:triage")
      @github.transition_label(epic_number, add: "agent:epic") if @github.respond_to?(:transition_label)

      created_by_key = {}
      created_list = []

      tasks = Array(split_plan["tasks"])
      tasks = tasks.select { |t| t["pilot"] == true }.first(1) if pilot_only

      tasks.each do |task|
        dep_numbers = Array(task["depends_on_keys"]).filter_map { |k| created_by_key[k] }
        body = format_child_body(
          epic_number: epic_number,
          dep_numbers: dep_numbers,
          pilot: task["pilot"] == true,
          body: task["body"],
          done_if: task["done_if"]
        )

        label = dep_numbers.empty? ? initial_label : "agent:waiting-deps"
        issue_num, url = create_github_issue(title: task["title"], body: body, label: label)
        created_by_key[task["key"]] = issue_num if issue_num
        created_list << { key: task["key"], number: issue_num, url: url, label: label, depends_on: dep_numbers, pilot: task["pilot"] == true }
      end

      created_list
    end

    def format_child_body(epic_number:, dep_numbers:, pilot:, body:, done_if:)
      deps_line = dep_numbers.empty? ? "none" : dep_numbers.map { |n| "##{n}" }.join(", ")
      header = [ "Parent: ##{epic_number}", "Depends on: #{deps_line}" ]
      header << "Pilot: true" if pilot

      <<~MD
        #{header.join("\n")}

        #{body.to_s.strip}

        ### Hard Stop Condition (`done_if`)
        #{done_if.to_s.strip}
      MD
    end

    private
    def create_github_issue(title:, body:, label:)
      if @github.respond_to?(:create_issue)
        res = @github.create_issue(title: title, body: body, label: label)
        if res.is_a?(Hash)
          return [ res[:number] || res["number"], res[:url] || res["url"] ]
        end
        num = res.to_s.match(%r{/issues/(\d+)})&.[](1)&.to_i
        return [ num, res.to_s ]
      end

      out, status = Open3.capture2e(
        "gh", "issue", "create",
        "--title", title,
        "--body", body,
        "--label", label,
        chdir: @repo_root
      )
      raise CommandError, "gh issue create failed:\n#{out}" unless status.success?

      url = out.strip
      num = url.match(%r{/issues/(\d+)})&.[](1)&.to_i
      [ num, url ]
    end
  end
end
