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

RSpec.describe Harness::Bot do
  class FakeGitHub
    attr_reader :issue_comments, :pr_comments, :transitions
    attr_accessor :issues_by_label, :pr_state_by_number, :inline_comments_by_pr, :diff_result

    def initialize
      @issues_by_label = Hash.new { |h, k| h[k] = [] }
      @pr_state_by_number = {}
      @inline_comments_by_pr = Hash.new { |h, k| h[k] = [] }
      @issue_comments = []
      @pr_comments = []
      @transitions = []
      @diff_result = { lines: 0, diff: "" }
    end

    def issues_with_label(label)
      @issues_by_label[label]
    end

    def comment_issue(number, body)
      @issue_comments << { number: number, body: body }
    end

    def transition_label(number, remove: nil, add: nil)
      @transitions << { number: number, remove: remove, add: add }
      @issues_by_label[remove]&.reject! { |issue| issue["number"] == number } if remove
    end

    def pr_view(pr_ref)
      @pr_state_by_number.fetch(pr_ref.to_i)
    end

    def pr_review_comments(pr_number)
      @inline_comments_by_pr[pr_number.to_i]
    end

    def comment_pr(pr_number, body)
      @pr_comments << { pr_number: pr_number, body: body }
    end

    def human_diff(_agent_sha, _merge_sha)
      @diff_result
    end
  end

  class FakeRouterBackend < Harness::Backends::Base
    def initialize(payload)
      @payload = payload
    end

    def name
      "fake"
    end

    def run(output_file:, **)
      json = JSON.generate(@payload)
      File.write(output_file, json)
      Harness::Backends::Result.new(output: json, duration_sec: 0.1, command: [ "fake" ])
    end
  end

  it "runs full closed loop: triage -> ready -> Draft PR -> PR review fix -> push -> merge outcome" do
    temp_dir = Dir.mktmpdir("harness-bot-spec")
    FileUtils.cp_r(File.join(Harness::Paths::ROOT, "templates/profile/."), Harness::Paths.profile(temp_dir))

    begin
      github = FakeGitHub.new
      store = Harness::IssueStore.new(repo_root: temp_dir)
      logger = Harness::Logger.new(File.join(Harness::Paths.profile(temp_dir), "runs", "bot.log"))
      telemetry = Harness::Telemetry.new(File.join(Harness::Paths.profile(temp_dir), "runs", "telemetry.jsonl"))

      triage_payload = {
        "kind" => "feature",
        "playbook" => "feature",
        "ready_to_execute" => true,
        "risk_level" => "low",
        "affected_layers" => [ "query", "dto", "specs" ],
        "acceptance_criteria" => [
          { "id" => "AC-1", "criterion" => "Query returns immutable DTO", "verification_method" => "unit_test" }
        ],
        "done_if" => "The unit and architecture checks pass",
        "needs_qa_demo" => true,
        "qa_reason" => "Changes filter controls visible to visitors.",
        "missing_questions" => [],
        "rationale" => "Clear scope in filter module."
      }
      router = Harness::Router.new(
        repo_root: temp_dir,
        backend: FakeRouterBackend.new(triage_payload),
        logger: logger
      )

      runner_calls = []
      runner_factory = lambda do |**kwargs|
        runner_calls << kwargs
        if kwargs[:push_only]
          { pr_url: nil, head_sha: "sha_after_review_fix" }
        else
          { pr_url: "https://github.com/example/sample/pull/42", head_sha: "sha_initial_pr" }
        end
      end

      bot = described_class.new(
        repo_root: temp_dir,
        github: github,
        store: store,
        router: router,
        logger: logger,
        telemetry: telemetry,
        runner_factory: runner_factory
      )

      # Tick 1: Issue arrives with agent:triage -> stops safely at agent:needs-info with AC contract.
      issue = { "number" => 17, "title" => "Add filter DTO", "body" => "Need filter DTO", "comments" => [] }
      github.issues_by_label["agent:triage"] = [ issue ]
      bot.tick!

      expect(store.find(17)["state"]).to eq("agent:needs-info")
      expect(github.issue_comments.last[:body]).to include("<!-- HARNESS_CONTRACT -->")
      expect(github.issue_comments.last[:body]).to include("AC-1")

      # Tick 2: Human flips issue to agent:ready -> Bot runs pipeline and opens Draft PR #42.
      issue["body"] = "Need a filter DTO\n\n## Dependencies\nNone"
      github.issues_by_label["agent:ready"] = [ issue ]
      github.pr_state_by_number[42] = { "number" => 42, "state" => "OPEN", "baseRefName" => "main", "reviews" => [] }
      bot.tick!

      expect(runner_calls.size).to eq(1)
      expect(runner_calls.last[:playbook]).to eq("feature")
      expect(runner_calls.last[:open_pr]).to be(true)
      expect(runner_calls.last[:run_qa]).to be(true)
      expect(runner_calls.last[:brief]).to include(issue["body"])
      expect(runner_calls.last[:brief]).to include("## Dependencies")
      expect(store.find(17)["state"]).to eq("agent:review")
      expect(store.find(17)["pr_number"]).to eq(42)

      # Tick 3: Human submits CHANGES_REQUESTED review + inline comment -> Bot runs babysit-pr & pushes.
      github.pr_state_by_number[42] = {
        "number" => 42,
        "state" => "OPEN",
        "baseRefName" => "main",
        "reviews" => [
          {
            "id" => "REV_100",
            "state" => "CHANGES_REQUESTED",
            "body" => "Please freeze array fields in DTO.",
            "author" => { "login" => "maintainer" }
          }
        ]
      }
      github.inline_comments_by_pr[42] = [
        {
          "id" => 901,
          "pull_request_review_id" => "REV_100",
          "path" => "src/filter.rb",
          "line" => 14,
          "body" => "Use `.freeze` on array member."
        }
      ]

      bot.tick!

      expect(runner_calls.size).to eq(2)
      expect(runner_calls.last[:playbook]).to eq("babysit-pr")
      expect(runner_calls.last[:push_only]).to be(true)
      expect(runner_calls.last[:skip_architect]).to be(true)
      expect(runner_calls.last[:brief]).to include("src/filter.rb:14")
      expect(runner_calls.last[:brief]).to include("Use `.freeze` on array member.")
      expect(store.find(17)["handled_review_ids"]).to eq([ "REV_100" ])
      expect(store.find(17)["agent_head_sha"]).to eq("sha_after_review_fix")
      expect(github.pr_comments.last[:body]).to include("Addressed 1 submitted review(s)")

      # Tick 4: No new review -> Bot does NOT re-run babysit-pr.
      bot.tick!
      expect(runner_calls.size).to eq(2)

      # Tick 5: Human merges PR #42 after making 25 lines of manual edits -> Bot records merged_edited & snapshot.
      github.pr_state_by_number[42] = {
        "number" => 42,
        "state" => "MERGED",
        "mergeCommit" => { "oid" => "sha_merged_final" },
        "reviews" => github.pr_state_by_number[42]["reviews"]
      }
      github.diff_result = { lines: 25, diff: "diff --git a/foo.rb b/foo.rb\n+manual edit\n" }

      bot.tick!

      final_record = store.find(17)
      expect(final_record["state"]).to eq("merged")
      expect(final_record["outcome"]).to eq("merged_edited")
      expect(final_record["human_diff_lines"]).to eq(25)
      expect(final_record["retro_processed"]).to be(false)
      expect(File.exist?(final_record["human_diff_path"])).to be(true)
      expect(File.exist?(final_record["reviews_snapshot_path"])).to be(true)

      events = File.readlines(File.join(Harness::Paths.profile(temp_dir), "runs", "telemetry.jsonl"), chomp: true).map { |l| JSON.parse(l) }
      expect(events.last["event"]).to eq("pr_outcome")
      expect(events.last["outcome"]).to eq("merged_edited")
      expect(events.last["human_diff_lines"]).to eq(25)
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "posts detailed Arbiter findings on GitHub when a task blocks on ReviewError" do
    temp_dir = Dir.mktmpdir("harness-bot-blocked-spec")
    FileUtils.cp_r(File.join(Harness::Paths::ROOT, "templates/profile/."), Harness::Paths.profile(temp_dir))

    begin
      github = FakeGitHub.new
      store = Harness::IssueStore.new(repo_root: temp_dir)
      logger = Harness::Logger.new(File.join(Harness::Paths.profile(temp_dir), "runs", "bot.log"))
      telemetry = Harness::Telemetry.new(File.join(Harness::Paths.profile(temp_dir), "runs", "telemetry.jsonl"))

      store.save(42, {
        "state" => "agent:ready",
        "contract" => {
          "playbook" => "feature",
          "done_if" => "All specs pass",
          "acceptance_criteria" => []
        }
      })

      review_payload = {
        "approved" => false,
        "summary" => "[Arbiter antigravity:claude-opus-5-5-high: REJECTED] Cross-domain record leak found.",
        "verdicts" => [
          { "reviewer" => "codex:model-a", "approved" => false, "summary" => "Found record leak" },
          { "reviewer" => "antigravity:model-b", "approved" => false, "summary" => "Found record leak" }
        ],
        "architecture_violations" => [
          {
            "file" => "src/query.rb:12",
            "rule" => "Persistence boundary",
            "severity" => "high",
            "risk" => "high",
            "explanation" => "Direct cross-domain record query."
          }
        ],
        "blocking_issues" => [
          {
            "file" => "src/query.rb:20",
            "severity" => "high",
            "risk" => "high",
            "issue" => "Unhandled nil filter.",
            "fix_hint" => "Validate filter before query."
          }
        ]
      }

      runner_factory = lambda do |**|
        raise Harness::ReviewError.new("Arbitrage review rejected after 2 round(s).", review: review_payload)
      end

      bot = described_class.new(
        repo_root: temp_dir,
        github: github,
        store: store,
        router: nil,
        logger: logger,
        telemetry: telemetry,
        runner_factory: runner_factory
      )

      github.issues_by_label["agent:ready"] = [
        { "number" => 42, "title" => "Demo", "body" => "Body", "comments" => [] }
      ]
      bot.tick!

      comment = github.issue_comments.last[:body]
      expect(comment).to include("### Arbiter Verdict")
      expect(comment).to include("Cross-domain record leak found.")
      expect(comment).to include("`codex:model-a`: **REJECTED**")
      expect(comment).to include("src/query.rb:12")
      expect(comment).to include("Unhandled nil filter.")
      expect(comment).to include("Validate filter before query.")
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "resumes PR babysitting when a blocked issue is manually moved back to agent:review on GitHub" do
    temp_dir = Dir.mktmpdir("harness-bot-resync-spec")
    begin
      github = FakeGitHub.new
      store = Harness::IssueStore.new(repo_root: temp_dir)
      logger = Harness::Logger.new(File.join(Harness::Paths.profile(temp_dir), "runs", "bot.log"))
      telemetry = Harness::Telemetry.new(File.join(Harness::Paths.profile(temp_dir), "runs", "telemetry.jsonl"))

      store.save(44, {
        "issue_number" => 44,
        "state" => "agent:blocked",
        "task_id" => "gh-44",
        "pr_number" => 60,
        "handled_review_ids" => [ "100" ]
      })

      github.issues_by_label["agent:review"] = [ { "number" => 44, "title" => "Issue 44" } ]
      github.pr_state_by_number[60] = {
        "state" => "OPEN",
        "baseRefName" => "main",
        "reviews" => [
          { "id" => "200", "state" => "CHANGES_REQUESTED", "body" => "Please simplify FilterParams." }
        ]
      }

      runner_calls = []
      runner_factory = lambda do |**kwargs|
        runner_calls << kwargs
        { pr_url: nil, head_sha: "abc1234567" }
      end

      bot = described_class.new(
        repo_root: temp_dir,
        github: github,
        store: store,
        router: nil,
        logger: logger,
        telemetry: telemetry,
        runner_factory: runner_factory
      )

      bot.tick!

      expect(runner_calls.size).to eq(1)
      expect(runner_calls.first[:playbook]).to eq("babysit-pr")
      expect(store.find(44)["state"]).to eq("agent:review")
      expect(store.find(44)["handled_review_ids"]).to include("200")
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
