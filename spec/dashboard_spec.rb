require "json"
require "tmpdir"
require "fileutils"

require_relative "spec_helper"

require "harness/dashboard"

RSpec.describe Harness::Dashboard do
  it "aggregates KPIs, runs, sessions, QA media, and serves safe log/media routes" do
    temp_dir = Dir.mktmpdir("harness-dash-spec")
    runs_dir = File.join(Harness::Paths.profile(temp_dir), "runs")
    FileUtils.mkdir_p(File.join(runs_dir, "t-1", "qa"))

    begin
      File.write(File.join(runs_dir, "bot.log"), "[10:00:00] [BOT] Idle\n")
      File.write(File.join(runs_dir, "telemetry.jsonl"), [
        JSON.generate(
          task_id: "t-1",
          dry_run: false,
          verify_loops: 1,
          review_disagreements: 1,
          failure_categories: [],
          usage: { input_tokens: 10_000, cached_input_tokens: 5_000, output_tokens: 1_000, total_tokens: 11_000 },
          estimated_cost_usd: 0.025
        ),
        JSON.generate(event: "pr_outcome", outcome: "merged_clean")
      ].join("\n") + "\n")
      File.write(File.join(runs_dir, "t-1", "metrics.json"), JSON.generate(task_id: "t-1", status: "verified", duration_sec: 12.0))
      File.write(File.join(runs_dir, "t-1", "qa", "qa-report.json"), JSON.generate(scenario: "smoke", passed: true))
      File.binwrite(File.join(runs_dir, "t-1", "qa", "demo-mobile.mp4"), "FAKE_MP4_BYTES")

      dashboard = described_class.new(repo_root: temp_dir)
      state = dashboard.state_snapshot

      expect(state[:kpis][:total_runs]).to eq(1)
      expect(state[:kpis][:first_pass_rate]).to eq(100.0)
      expect(state[:kpis][:cache_hit_pct]).to eq(50.0)
      expect(state[:kpis][:merged_clean]).to eq(1)
      expect(state[:qa_media].first[:videos]).to eq([ "/media/t-1/qa/demo-mobile.mp4" ])

      status, _, body = dashboard.route_request(method: "GET", path: "/api/log", query: { "file" => "bot.log" })
      expect(status).to eq(200)
      expect(body).to include("[BOT] Idle")

      # Rejects path traversal outside the profile runs directory
      bad_status, = dashboard.route_request(method: "GET", path: "/api/log", query: { "file" => "../../config/database.yml" })
      expect(bad_status).to eq(404)

      # Serves media with Range support for HTML5 video
      part_status, headers, chunk = dashboard.route_request(
        method: "GET",
        path: "/media/t-1/qa/demo-mobile.mp4",
        query: {},
        headers: { "range" => "bytes=0-3" }
      )
      expect(part_status).to eq(206)
      expect(headers["Content-Range"]).to eq("bytes 0-3/14")
      expect(chunk).to eq("FAKE")

      # Serves per-run detail payload and jailed artifact inspection
      run_status, _, run_json = dashboard.route_request(method: "GET", path: "/api/run", query: { "id" => "t-1" })
      expect(run_status).to eq(200)
      detail = JSON.parse(run_json)
      expect(detail["task_id"]).to eq("t-1")
      expect(detail["qa"].first["videos"]).to eq([ "/media/t-1/qa/demo-mobile.mp4" ])

      art_status, _, art_body = dashboard.route_request(method: "GET", path: "/api/artifact", query: { "id" => "t-1", "file" => "metrics.json" })
      expect(art_status).to eq(200)
      expect(art_body).to include("\"t-1\"")
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
