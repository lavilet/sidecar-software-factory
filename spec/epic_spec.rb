require "json"
require "tmpdir"
require "fileutils"

require_relative "spec_helper"

require "harness/errors"
require "harness/logger"
require "harness/telemetry"
require "harness/backends/base"
require "harness/epic_parser"
require "harness/issue_store"
require "harness/router"
require "harness/bot"

RSpec.describe "Harness Epic & Dependency Graph orchestration" do
  describe Harness::EpicParser do
    it "parses Parent, Depends on, and Pilot metadata lines" do
      body = <<~MD
        Parent: #41
        Depends on: #42, #43
        Pilot: true

        Implement repository slice.
      MD

      meta = described_class.parse(body)
      expect(meta.parent_issue).to eq(41)
      expect(meta.depends_on).to eq([ 42, 43 ])
      expect(meta.pilot).to be(true)
    end

    it "parses Markdown ## Dependencies sections and Pilot outcomes from planning issues" do
      pilot_body = <<~MD
        ## Outcome
        Pilot the target convention through /items and /search.

        ## Initiative context
        Parent: #41

        ## Dependencies
        None
      MD

      child_body = <<~MD
        ## Initiative context
        Parent: #41

        ## Dependencies
        #42
        #43

        ## Estimate and budget
        ```json
        {}
        ```
      MD

      pilot_meta = described_class.parse(pilot_body)
      expect(pilot_meta.parent_issue).to eq(41)
      expect(pilot_meta.depends_on).to eq([])
      expect(pilot_meta.pilot).to be(true)

      child_meta = described_class.parse(child_body)
      expect(child_meta.parent_issue).to eq(41)
      expect(child_meta.depends_on).to eq([ 42, 43 ])
      expect(child_meta.pilot).to be(false)
    end
  end

  it "parks dependent children on agent:waiting-deps, injects Parent Epic context, and auto-unblocks after pilot merges" do
    temp_dir = Dir.mktmpdir("harness-epic-spec")
    FileUtils.cp_r(File.join(Harness::Paths::ROOT, "templates/profile/."), Harness::Paths.profile(temp_dir))

    begin
      issues_by_number = {
        41 => { "number" => 41, "title" => "Move persistence to repositories", "body" => "Shared Epic #41 architecture", "state" => "OPEN", "labels" => [ { "name" => "agent:epic" } ] },
        42 => { "number" => 42, "title" => "Catalog repository pilot", "body" => "Parent: #41\nDepends on: none\nPilot: true\n\nBuild catalog repo.", "state" => "OPEN", "labels" => [] },
        43 => { "number" => 43, "title" => "Accounts repository", "body" => "Parent: #41\nDepends on: #42\n\nBuild accounts repo.", "state" => "OPEN", "labels" => [] }
      }
      issues_by_label = Hash.new { |h, k| h[k] = [] }
      comments = []
      transitions = []
      pr_states = {}

      github = Object.new
      github.define_singleton_method(:issues_with_label) { |label| issues_by_label[label].dup }
      github.define_singleton_method(:issue_view) { |num| issues_by_number.fetch(num.to_i) }
      github.define_singleton_method(:comment_issue) { |num, body| comments << { number: num, body: body } }
      github.define_singleton_method(:transition_label) do |num, remove: nil, add: nil|
        transitions << { number: num, remove: remove, add: add }
        issues_by_label[remove]&.reject! { |i| i["number"] == num } if remove
        issues_by_label[add] << issues_by_number[num] if add && !issues_by_label[add].any? { |i| i["number"] == num }
      end
      github.define_singleton_method(:pr_view) { |pr_ref| pr_states.fetch(pr_ref.to_i) }
      github.define_singleton_method(:pr_review_comments) { |_| [] }
      github.define_singleton_method(:human_diff) { |_, _| { lines: 0, diff: "" } }

      store = Harness::IssueStore.new(repo_root: temp_dir)
      logger = Harness::Logger.new(File.join(Harness::Paths.profile(temp_dir), "runs", "bot.log"))
      telemetry = Harness::Telemetry.new(File.join(Harness::Paths.profile(temp_dir), "runs", "telemetry.jsonl"))

      # Seed approved contracts for #42 (pilot) and #43 (depends on #42).
      contract = {
        "kind" => "refactor",
        "playbook" => "feature",
        "ready_to_execute" => true,
        "risk_level" => "low",
        "affected_layers" => [ "query", "specs" ],
        "acceptance_criteria" => [ { "id" => "AC-1", "criterion" => "Passes", "verification_method" => "unit_spec" } ],
        "done_if" => "verify green",
        "needs_qa_demo" => false,
        "qa_reason" => "Backend refactor",
        "missing_questions" => [],
        "rationale" => "ok"
      }
      store.save(42, { "state" => "agent:ready", "contract" => contract })
      store.save(43, { "state" => "agent:ready", "contract" => contract })

      dispatched = []
      runner_factory = lambda do |**kwargs|
        dispatched << kwargs
        pr_num = kwargs[:task_id] == "gh-42" ? 101 : 102
        pr_states[pr_num] = { "number" => pr_num, "state" => "OPEN", "baseRefName" => "main", "reviews" => [] }
        { pr_url: "https://github.com/example/sample/pull/#{pr_num}", head_sha: "sha-#{pr_num}" }
      end

      pilot_retros = []
      bot = Harness::Bot.new(
        repo_root: temp_dir,
        github: github,
        store: store,
        router: nil,
        logger: logger,
        telemetry: telemetry,
        runner_factory: runner_factory,
        on_merge: ->(num, pilot: false) { pilot_retros << { num: num, pilot: pilot } }
      )

      # Queue #43 (blocked on #42) BEFORE #42 (pilot) AND include epic #41 (must be ignored).
      issues_by_label["agent:ready"] = [ issues_by_number[41], issues_by_number[43], issues_by_number[42] ]
      bot.tick!

      # #43 moved to agent:waiting-deps, #41 ignored, #42 dispatched with Epic #41 context!
      expect(store.find(43)["state"]).to eq("agent:waiting-deps")
      expect(dispatched.size).to eq(1)
      expect(dispatched.first[:task_id]).to eq("gh-42")
      expect(dispatched.first[:brief]).to include("Parent Epic Context (#41: Move persistence to repositories)")
      expect(comments.any? { |c| c[:number] == 41 && c[:body].include?("Child #42 [PILOT] opened Draft PR") }).to be(true)

      # Now #42 merges and closes -> triggers Pilot Retro & next tick unblocks and dispatches #43!
      pr_states[101] = { "number" => 101, "state" => "MERGED", "mergeCommit" => { "oid" => "sha-101" }, "reviews" => [] }
      issues_by_number[42]["state"] = "CLOSED"
      bot.tick!

      expect(pilot_retros).to eq([ { num: 42, pilot: true } ])
      expect(comments.any? { |c| c[:number] == 41 && c[:body].include?("[PILOT COMPLETE]") }).to be(true)
      expect(dispatched.map { |d| d[:task_id] }).to eq([ "gh-42", "gh-43" ])

      # Orphaned agent:in-progress issue after bot restart is automatically moved back to agent:ready.
      issues_by_label["agent:in-progress"] = [ issues_by_number[43] ]
      bot.recover_orphaned_in_progress!
      expect(store.find(43)["state"]).to eq("agent:ready")
      expect(issues_by_label["agent:ready"].map { |i| i["number"] }).to include(43)
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
