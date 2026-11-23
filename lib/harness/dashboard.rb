require "time"
require "json"
require "socket"
require "uri"

module Harness
  # Zero-dependency local Kanban + Per-Run Modal HTTP dashboard (pure Ruby stdlib TCPServer).
  # Sidebar views: Kanban Board (click any run/issue for isolated per-run modal with Logs, Review/Arbiter,
  # QA Videos, Costs/Sessions, Artifacts), Global Telemetry, Bot Live Log, Retro Lessons, Scout Proposals.
  class Dashboard
    MIME_TYPES = {
      ".html" => "text/html; charset=utf-8",
      ".json" => "application/json; charset=utf-8",
      ".mp4" => "video/mp4",
      ".webm" => "video/webm",
      ".png" => "image/png",
      ".md" => "text/plain; charset=utf-8",
      ".log" => "text/plain; charset=utf-8",
      ".diff" => "text/plain; charset=utf-8"
    }.freeze

    def initialize(repo_root:, host: "127.0.0.1", port: 4127)
      @repo_root = File.expand_path(repo_root)
      @runs_dir = File.join(Harness::Paths.profile(@repo_root), "runs")
      @host = host
      @port = port
    end

    def state_snapshot
      runs = load_runs
      issues = load_issues
      telemetry = load_telemetry
      lessons = load_lessons
      scout = load_latest_scout
      qa_media = discover_qa_media

      run_events = telemetry.reject { |e| e["event"] == "pr_outcome" || e["dry_run"] == true }
      outcomes = telemetry.select { |e| e["event"] == "pr_outcome" }

      total_tokens = run_events.sum { |e| e.dig("usage", "total_tokens").to_i }
      total_input = run_events.sum { |e| e.dig("usage", "input_tokens").to_i }
      total_cached = run_events.sum { |e| e.dig("usage", "cached_input_tokens").to_i }
      total_cost = run_events.sum { |e| e["estimated_cost_usd"].to_f }.round(4)
      first_pass = run_events.count { |e| e["verify_loops"].to_i == 1 && Array(e["failure_categories"]).empty? }
      disagreements = run_events.sum { |e| e["review_disagreements"].to_i }
      budget_alerts = run_events.count { |e| e["budget_exceeded"] == true }

      failures = Hash.new(0)
      run_events.each { |e| Array(e["failure_categories"]).each { |c| failures[c] += 1 } }

      {
        generated_at: Time.now.utc.iso8601,
        kpis: {
          total_runs: run_events.size,
          first_pass_rate: run_events.empty? ? 0.0 : (first_pass.to_f / run_events.size * 100).round(1),
          total_tokens: total_tokens,
          cache_hit_pct: total_input.zero? ? 0.0 : (total_cached.to_f / total_input * 100).round(1),
          estimated_cost_usd: total_cost,
          avg_tokens_per_run: run_events.empty? ? 0 : (total_tokens / run_events.size),
          review_disagreements: disagreements,
          budget_alerts: budget_alerts,
          merged_clean: outcomes.count { |e| e["outcome"] == "merged_clean" },
          merged_edited: outcomes.count { |e| e["outcome"] == "merged_edited" },
          abandoned: outcomes.count { |e| e["outcome"] == "abandoned" },
          top_failures: failures.sort_by { |_, count| -count }.to_h
        },
        cards: build_kanban_cards(runs: runs, issues: issues),
        issues: issues,
        runs: runs,
        qa_media: qa_media,
        lessons: lessons.last(20).reverse,
        scout: scout,
        log_files: available_log_files
      }
    end

    def run_detail(task_id)
      safe_id = task_id.to_s.strip
      return nil if safe_id.empty? || safe_id.include?("/") || safe_id.include?("..")

      run_dir = File.join(@runs_dir, safe_id)
      issue_num = safe_id.match(/\Agh-(\d+)\z/)&.[](1)&.to_i
      issue = issue_num ? load_issues.find { |i| i["issue_number"].to_i == issue_num } : nil
      return nil unless Dir.exist?(run_dir) || issue

      metrics = read_json_safe(File.join(run_dir, "metrics.json")) || { "task_id" => safe_id, "status" => issue&.[]("state") || "unknown" }
      if issue && issue["state"]
        metrics = metrics.merge("last_run_status" => metrics["status"], "status" => issue["state"])
      end
      sessions = read_json_safe(File.join(run_dir, "sessions.json")) || []
      arbitrage_reviews = Dir.glob(File.join(run_dir, "review-r*-arbitrage.json")).sort.filter_map do |path|
        data = read_json_safe(path)
        data ? { "file" => File.basename(path), "data" => data } : nil
      end
      raw_reviews = Dir.glob(File.join(run_dir, "review-r*-*.json")).sort.reject { |p| p.end_with?("-arbitrage.json") }.filter_map do |path|
        data = read_json_safe(path)
        data ? { "file" => File.basename(path), "data" => data } : nil
      end

      qa_entries = %w[ qa-repro qa ].filter_map do |sub|
        sub_dir = File.join(run_dir, sub)
        report = read_json_safe(File.join(sub_dir, "qa-report.json"))
        next unless report

        rel = "#{safe_id}/#{sub}"
        {
          "kind" => sub == "qa-repro" ? "before_repro" : "after_verified",
          "report" => report,
          "videos" => recordings(sub_dir).map { |f| "/media/#{rel}/#{File.basename(f)}" },
          "screenshots" => Dir.glob(File.join(sub_dir, "*.png")).sort.map { |f| "/media/#{rel}/#{File.basename(f)}" }
        }
      end

      artifacts = if Dir.exist?(run_dir)
        Dir.children(run_dir).sort.select { |name| File.file?(File.join(run_dir, name)) }.map do |name|
          { "name" => name, "size" => File.size(File.join(run_dir, name)) }
        end
      else
        []
      end

      log_files = artifacts.map { |a| a["name"] }.select { |n| n.end_with?(".log") }

      {
        "task_id" => safe_id,
        "metrics" => metrics,
        "issue" => issue,
        "sessions" => sessions,
        "attach_cmd" => "factory attach #{safe_id}",
        "arbitrage_reviews" => arbitrage_reviews,
        "raw_reviews" => raw_reviews,
        "qa" => qa_entries,
        "logs" => log_files,
        "artifacts" => artifacts
      }
    end

    def serve!
      server = TCPServer.new(@host, @port)
      puts "[DASHBOARD] Serving http://#{@host}:#{@port} (runs_dir=#{@runs_dir})"
      $stdout.flush

      loop do
        client = server.accept
        Thread.new(client) { |conn| handle_connection(conn) }
      end
    ensure
      server&.close
    end

    def route_request(method:, path:, query:, headers: {})
      return [ 405, { "Content-Type" => "text/plain" }, "Method Not Allowed" ] unless method == "GET"

      case path
      when "/"
        [ 200, { "Content-Type" => "text/html; charset=utf-8" }, html_page ]
      when "/api/state"
        [ 200, { "Content-Type" => "application/json; charset=utf-8" }, JSON.generate(state_snapshot) ]
      when "/api/run"
        detail = run_detail(query["id"])
        return [ 404, { "Content-Type" => "application/json" }, JSON.generate(error: "Run not found") ] unless detail

        [ 200, { "Content-Type" => "application/json; charset=utf-8" }, JSON.generate(detail) ]
      when "/api/artifact"
        serve_artifact(query["id"], query["file"])
      when "/api/log"
        serve_log(query["file"] || "bot.log", (query["lines"] || 160).to_i)
      else
        if path.start_with?("/media/")
          serve_media(URI.decode_www_form_component(path.delete_prefix("/media/")), headers)
        else
          [ 404, { "Content-Type" => "text/plain" }, "Not Found" ]
        end
      end
    end

    private
    def handle_connection(conn)
      request_line = conn.gets
      return unless request_line

      method, full_target, = request_line.strip.split(" ", 3)
      headers = {}
      while (line = conn.gets)
        break if line == "\r\n" || line == "\n"

        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if key && value
      end

      uri = URI.parse(full_target || "/")
      query = URI.decode_www_form(uri.query.to_s).to_h
      status, resp_headers, body = route_request(method: method, path: uri.path, query: query, headers: headers)

      reason = { 200 => "OK", 206 => "Partial Content", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed" }.fetch(status, "OK")
      conn.write("HTTP/1.1 #{status} #{reason}\r\n")
      resp_headers["Content-Length"] ||= body.bytesize.to_s
      resp_headers["Connection"] = "close"
      resp_headers.each { |k, v| conn.write("#{k}: #{v}\r\n") }
      conn.write("\r\n")
      conn.write(body)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError, URI::InvalidURIError => error
      warn("[DASHBOARD] Connection error: #{error.class}: #{error.message}")
    ensure
      conn.close unless conn.closed?
    end

    def read_json_safe(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def safe_runs_path(relative_path)
      return nil unless Dir.exist?(@runs_dir)

      candidate = File.expand_path(relative_path.to_s, @runs_dir)
      return nil unless candidate.start_with?("#{@runs_dir}/") && File.file?(candidate)

      resolved = File.realpath(candidate)
      resolved if resolved.start_with?(File.realpath(@runs_dir) + "/")
    end

    def serve_artifact(task_id, filename)
      return [ 404, { "Content-Type" => "text/plain" }, "Artifact not found" ] if task_id.to_s.empty? || filename.to_s.empty?

      full = safe_runs_path(File.join(task_id.to_s, filename.to_s))
      return [ 404, { "Content-Type" => "text/plain" }, "Artifact not found" ] unless full

      content = File.read(full)
      content = "#{content.byteslice(0, 120_000)}\n\n... [TRUNCATED AT 120KB]" if content.bytesize > 120_000
      [ 200, { "Content-Type" => "text/plain; charset=utf-8" }, content ]
    end

    def serve_log(relative_file, max_lines)
      full = safe_runs_path(relative_file)
      return [ 404, { "Content-Type" => "text/plain" }, "Log not found: #{relative_file}" ] unless full

      lines = File.readlines(full, chomp: true).last([ max_lines, 500 ].min)
      [ 200, { "Content-Type" => "text/plain; charset=utf-8" }, lines.join("\n") ]
    end

    def serve_media(relative_path, headers)
      full = safe_runs_path(relative_path)
      return [ 404, { "Content-Type" => "text/plain" }, "Media not found" ] unless full

      ext = File.extname(full).downcase
      mime = MIME_TYPES.fetch(ext, "application/octet-stream")
      data = File.binread(full)
      total = data.bytesize

      if (range = headers["range"]) && (match = range.match(/bytes=(\d+)-(\d*)/))
        start_b = match[1].to_i
        end_b = match[2].empty? ? total - 1 : [ match[2].to_i, total - 1 ].min
        chunk = data.byteslice(start_b..end_b) || ""
        return [
          206,
          {
            "Content-Type" => mime,
            "Accept-Ranges" => "bytes",
            "Content-Range" => "bytes #{start_b}-#{end_b}/#{total}",
            "Content-Length" => chunk.bytesize.to_s
          },
          chunk
        ]
      end

      [ 200, { "Content-Type" => mime, "Accept-Ranges" => "bytes" }, data ]
    end

    def build_kanban_cards(runs:, issues:)
      by_task = {}

      runs.each do |run|
        id = run["task_id"]
        by_task[id] = {
          "task_id" => id,
          "column" => kanban_column(run["status"]),
          "status" => run["status"],
          "playbook" => run["playbook"],
          "duration_sec" => run["duration_sec"],
          "verify_loops" => run["verify_loops"],
          "review_loops" => run["review_loops"],
          "total_tokens" => run.dig("usage", "total_tokens").to_i,
          "estimated_cost_usd" => run["estimated_cost_usd"],
          "budget_exceeded" => run["budget_exceeded"] == true,
          "pr_url" => run["pr_url"],
          "updated_at" => run["finished_at"] || run["started_at"]
        }
      end

      issues.each do |issue|
        id = issue["task_id"] || "gh-#{issue["issue_number"]}"
        existing = by_task[id] || { "task_id" => id }
        by_task[id] = existing.merge(
          "issue_number" => issue["issue_number"],
          "column" => kanban_column(issue["state"]),
          "status" => issue["state"],
          "kind" => issue["kind"],
          "playbook" => issue["playbook"] || existing["playbook"],
          "pr_url" => issue["pr_url"] || existing["pr_url"],
          "pr_number" => issue["pr_number"],
          "parent_issue" => issue["parent_issue"],
          "depends_on" => Array(issue["depends_on"]),
          "pilot" => issue["pilot"] == true,
          "needs_qa_demo" => issue.dig("contract", "needs_qa_demo") == true,
          "updated_at" => issue["updated_at"] || existing["updated_at"]
        )
      end

      by_task.values.sort_by { |c| c["updated_at"].to_s }.reverse
    end

    def kanban_column(status)
      case status.to_s
      when "agent:triage", "agent:needs-info", "agent:waiting-deps" then "triage"
      when "agent:ready" then "ready"
      when "agent:in-progress", "running" then "in_progress"
      when "agent:review", "pr_opened", "pr_updated", "verified", "dry_run_ok" then "review"
      when "agent:blocked", "verify_blocked", "review_blocked", "qa_failed", "error", "abandoned" then "blocked"
      when "merged", "agent:merged" then "done"
      else "in_progress"
      end
    end

    def load_runs
      return [] unless Dir.exist?(@runs_dir)

      task_dirs = Dir.children(@runs_dir).select do |name|
        next false if %w[ issues ].include?(name)

        File.directory?(File.join(@runs_dir, name))
      end

      task_dirs.filter_map do |task_id|
        dir = File.join(@runs_dir, task_id)
        metrics = read_json_safe(File.join(dir, "metrics.json"))
        unless metrics
          next unless File.exist?(File.join(dir, "pipeline.log")) || Dir.exist?(File.join(dir, "qa"))

          metrics = { "task_id" => task_id, "status" => File.exist?(File.join(dir, "pipeline.log")) ? "running" : "qa_only" }
        end
        metrics["sessions"] = read_json_safe(File.join(dir, "sessions.json")) || []
        metrics["attach_cmd"] = "factory attach #{task_id}"
        metrics
      end.sort_by { |m| m["started_at"].to_s }.reverse
    end

    def load_issues
      dir = File.join(@runs_dir, "issues")
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.json")).filter_map do |path|
        next unless File.basename(path).match?(/\A\d+\.json\z/)

        read_json_safe(path)
      end.sort_by { |i| i["updated_at"].to_s }.reverse
    end

    def load_telemetry
      path = File.join(@runs_dir, "telemetry.jsonl")
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def load_lessons
      path = File.join(@runs_dir, "lessons.jsonl")
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def load_latest_scout
      read_json_safe(File.join(@runs_dir, "scout-latest.json"))
    end

    def discover_qa_media
      return [] unless Dir.exist?(@runs_dir)

      Dir.glob(File.join(@runs_dir, "*", "{qa,qa-repro}", "qa-report.json")).sort.reverse.filter_map do |path|
        report = read_json_safe(path)
        next unless report

        rel_dir = File.dirname(path).delete_prefix("#{@runs_dir}/")
        task_id = rel_dir.split("/").first
        videos = recordings(File.dirname(path)).map { |f| "/media/#{rel_dir}/#{File.basename(f)}" }
        shots = Dir.glob(File.join(File.dirname(path), "*.png")).sort.map { |f| "/media/#{rel_dir}/#{File.basename(f)}" }
        { task_id: task_id, dir: rel_dir, scenario: report["scenario"], passed: report["passed"], videos: videos, screenshots: shots }
      end
    end

    def recordings(dir)
      Dir.glob(File.join(dir, "*.{mp4,webm}")).sort.group_by { |f| File.basename(f, ".*") }.values.map(&:first)
    end

    def available_log_files
      return [] unless Dir.exist?(@runs_dir)

      files = []
      files << "bot.log" if File.exist?(File.join(@runs_dir, "bot.log"))
      Dir.glob(File.join(@runs_dir, "*", "pipeline.log")).sort.reverse.each do |path|
        files << path.delete_prefix("#{@runs_dir}/")
      end
      files
    end

    def html_page
      <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width,initial-scale=1" />
            <title>Sidecar Software Factory</title>
            <style>
              :root { --bg:#0d1017; --sidebar:#121621; --card:#171c28; --card2:#1d2333; --border:#273043; --text:#e6edf3; --muted:#8b949e; --ok:#2ea043; --warn:#d29922; --err:#f85149; --accent:#58a6ff; }
              * { box-sizing:border-box; }
              body { margin:0; font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); display:flex; min-height:100vh; }
              aside { width:220px; background:var(--sidebar); border-right:1px solid var(--border); padding:18px 12px; display:flex; flex-direction:column; gap:6px; position:sticky; top:0; height:100vh; flex-shrink:0; }
              .brand { font-size:15px; font-weight:700; padding:6px 10px 14px; border-bottom:1px solid var(--border); margin-bottom:6px; }
              .nav-btn { background:transparent; border:0; color:var(--muted); text-align:left; padding:9px 12px; border-radius:8px; cursor:pointer; font-size:13px; font-weight:500; }
              .nav-btn:hover { background:var(--card); color:var(--text); }
              .nav-btn.active { background:rgba(88,166,255,.15); color:var(--accent); }
              main { flex:1; padding:22px 26px; overflow-x:auto; }
              .top-bar { display:flex; justify-content:space-between; align-items:center; margin-bottom:18px; }
              h1 { margin:0; font-size:20px; }
              h2 { margin:0 0 12px; font-size:16px; }
              h3 { margin:0 0 8px; font-size:14px; }
              .muted { color:var(--muted); font-size:12px; }
              .kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:18px; }
              .card { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:14px; margin-bottom:14px; }
              .kpi-val { font-size:22px; font-weight:700; margin-top:4px; }
              .kanban { display:grid; grid-template-columns:repeat(6,minmax(210px,1fr)); gap:12px; align-items:start; }
              .col { background:var(--sidebar); border:1px solid var(--border); border-radius:10px; padding:10px; min-height:240px; }
              .col-head { display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
              .run-card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:10px 11px; margin-bottom:8px; cursor:pointer; transition:border-color .15s,transform .1s; }
              .run-card:hover { border-color:var(--accent); transform:translateY(-1px); }
              .badge { display:inline-block; padding:2px 7px; border-radius:999px; font-size:11px; font-weight:600; background:#21262d; }
              .ok { background:rgba(46,160,67,.2); color:#56d364; }
              .warn { background:rgba(210,153,34,.2); color:#e3b341; }
              .err { background:rgba(248,81,73,.2); color:#ff7b72; }
              .info { background:rgba(88,166,255,.18); color:#79c0ff; }
              button { background:#21262d; color:var(--text); border:1px solid var(--border); border-radius:6px; padding:5px 10px; cursor:pointer; font-size:12px; }
              button:hover { border-color:var(--accent); color:var(--accent); }
              table { width:100%; border-collapse:collapse; font-size:13px; }
              th,td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--border); vertical-align:top; }
              th { color:var(--muted); font-size:12px; }
              code,pre { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
              pre.log { background:#090b10; border:1px solid var(--border); border-radius:8px; padding:12px; max-height:480px; overflow:auto; font-size:12px; white-space:pre-wrap; margin:8px 0 0; }
              a { color:var(--accent); text-decoration:none; }
              .view { display:none; }
              .view.active { display:block; }

              /* Per-run modal */
              .modal-backdrop { position:fixed; inset:0; background:rgba(0,0,0,.68); display:none; justify-content:flex-end; z-index:50; }
              .modal-backdrop.open { display:flex; }
              .modal { width:min(960px,94vw); height:100vh; background:var(--bg); border-left:1px solid var(--border); display:flex; flex-direction:column; }
              .modal-head { padding:16px 20px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center; gap:12px; background:var(--sidebar); }
              .modal-tabs { display:flex; gap:6px; padding:10px 20px; border-bottom:1px solid var(--border); background:var(--sidebar); flex-wrap:wrap; }
              .tab-btn { background:transparent; border:1px solid transparent; color:var(--muted); padding:6px 12px; border-radius:7px; cursor:pointer; font-size:13px; }
              .tab-btn.active { background:var(--card); border-color:var(--border); color:var(--text); }
              .modal-body { flex:1; overflow:auto; padding:18px 20px; }
              .media-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:12px; }
              video { width:100%; border-radius:8px; border:1px solid var(--border); background:#000; max-height:380px; }
              .shots { display:flex; gap:8px; flex-wrap:wrap; margin-top:8px; }
              .shots img { height:120px; border-radius:6px; border:1px solid var(--border); }
              select { background:#090b10; color:var(--text); border:1px solid var(--border); border-radius:6px; padding:5px 10px; }
              .log-feed { background:#090b10; border:1px solid var(--border); border-radius:8px; padding:10px; max-height:540px; overflow:auto; display:flex; flex-direction:column; gap:8px; margin-top:8px; }
              .log-entry { border:1px solid var(--border); border-left:3px solid #30363d; border-radius:6px; padding:8px 10px; background:#0f1319; }
              .log-entry.kind-agent { border-left-color:#58a6ff; background:rgba(88,166,255,.06); }
              .log-entry.kind-think { border-left-color:#bc8cff; background:rgba(188,140,255,.05); }
              .log-entry.kind-tool { border-left-color:#e3b341; background:rgba(210,153,34,.05); }
              .log-entry.kind-edit { border-left-color:#56d364; background:rgba(46,160,67,.06); }
              .log-entry.kind-error { border-left-color:#ff7b72; background:rgba(248,81,73,.08); }
              .log-meta { display:flex; gap:6px; align-items:center; flex-wrap:wrap; margin-bottom:4px; font-size:11px; }
              .log-body { margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; white-space:pre-wrap; word-break:break-word; color:var(--text); }
              .pill-btn.active { border-color:var(--accent); color:var(--accent); background:rgba(88,166,255,.12); }
            </style>
          </head>
          <body>
            <aside>
              <div class="brand">Sidecar Software Factory</div>
              <button class="nav-btn active" onclick="switchView('kanban', this)">Kanban &amp; Runs</button>
              <button class="nav-btn" onclick="switchView('telemetry', this)">Costs &amp; Telemetry</button>
              <button class="nav-btn" onclick="switchView('botlog', this)">Bot Live Log</button>
              <button class="nav-btn" onclick="switchView('retro', this)">Retro &amp; Lessons</button>
              <button class="nav-btn" onclick="switchView('scout', this)">Autonomous Scout</button>
              <div style="margin-top:auto;padding:10px;border-top:1px solid var(--border);" class="muted" id="side-status">Connecting...</div>
            </aside>

            <main>
              <div class="top-bar">
                <h1 id="view-title">Kanban &amp; Runs</h1>
                <button onclick="refreshAll()">Refresh</button>
              </div>

              <section id="view-kanban" class="view active">
                <div class="kpi-grid" id="mini-kpis"></div>
                <div class="kanban" id="kanban-board"></div>
              </section>

              <section id="view-telemetry" class="view">
                <div class="kpi-grid" id="full-kpis"></div>
                <div class="card">
                  <h2>Failure Categories</h2>
                  <div id="failures-table"></div>
                </div>
                <div class="card">
                  <h2>All Runs History</h2>
                  <div id="runs-table"></div>
                </div>
              </section>

              <section id="view-botlog" class="view">
                <div class="card">
                  <h2>bot.log (live tail)</h2>
                  <pre class="log" id="bot-log-view">Loading...</pre>
                </div>
              </section>

              <section id="view-retro" class="view">
                <div class="card">
                  <h2>Post-Merge Lessons Learned</h2>
                  <div id="lessons-view"></div>
                </div>
              </section>

              <section id="view-scout" class="view">
                <div class="card">
                  <h2>Autonomous Scout Proposals</h2>
                  <div id="scout-view"></div>
                </div>
              </section>
            </main>

            <div class="modal-backdrop" id="run-modal" onclick="if(event.target===this) closeModal()">
              <div class="modal">
                <div class="modal-head">
                  <div>
                    <h2 style="margin:0;" id="m-title">Run</h2>
                    <div class="muted" id="m-sub"></div>
                  </div>
                  <div style="display:flex;gap:8px;align-items:center;">
                    <button id="m-copy-attach">Copy attach cmd</button>
                    <button onclick="closeModal()">Close</button>
                  </div>
                </div>
                <div class="modal-tabs" id="m-tabs">
                  <button class="tab-btn active" onclick="switchTab('overview', this)">Overview</button>
                  <button class="tab-btn" onclick="switchTab('logs', this)">Logs</button>
                  <button class="tab-btn" onclick="switchTab('review', this)">Review &amp; Arbiter</button>
                  <button class="tab-btn" onclick="switchTab('qa', this)">QA Videos &amp; Shots</button>
                  <button class="tab-btn" onclick="switchTab('costs', this)">Costs &amp; Sessions</button>
                  <button class="tab-btn" onclick="switchTab('artifacts', this)">Artifacts</button>
                </div>
                <div class="modal-body" id="m-body">Loading...</div>
              </div>
            </div>

            <script>
              const esc = (s) => String(s ?? "").replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
              const badge = (s) => {
                const v = String(s || "");
                const cls = /verified|pr_opened|pr_updated|merged|ok|PASS|APPROVED|review|clean/.test(v) ? "ok"
                  : /blocked|fail|err|abandoned|REJECTED|violation|valid_blocker|critical|high/.test(v) ? "err"
                  : /nitpick|false_positive|low/.test(v) ? "info" : "warn";
                return `<span class="badge ${cls}">${esc(v)}</span>`;
              };
              let activeView = "kanban";
              let activeRunId = null;
              let activeTab = "overview";
              let activeRunData = null;
              let logMode = "structured";
              let logFilter = "all";
              let lastRunLogText = "";

              function copyText(txt, btn) {
                navigator.clipboard.writeText(txt);
                const old = btn.textContent;
                btn.textContent = "Copied!";
                setTimeout(() => btn.textContent = old, 1200);
              }

              function switchView(name, btn) {
                activeView = name;
                document.querySelectorAll(".view").forEach(v => v.classList.remove("active"));
                document.getElementById("view-" + name).classList.add("active");
                document.querySelectorAll(".nav-btn").forEach(b => b.classList.remove("active"));
                btn.classList.add("active");
                document.getElementById("view-title").textContent = btn.textContent;
                if (name === "botlog") loadBotLog();
              }

              async function openRun(taskId) {
                activeRunId = taskId;
                activeTab = "overview";
                document.querySelectorAll(".tab-btn").forEach((b, i) => b.classList.toggle("active", i === 0));
                document.getElementById("run-modal").classList.add("open");
                await refreshRunModal();
              }

              function closeModal() {
                activeRunId = null;
                document.getElementById("run-modal").classList.remove("open");
              }

              function switchTab(tab, btn) {
                activeTab = tab;
                document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
                btn.classList.add("active");
                renderRunTab();
              }

              async function refreshRunModal() {
                if (!activeRunId) return;
                const res = await fetch("/api/run?id=" + encodeURIComponent(activeRunId));
                if (!res.ok) return;
                activeRunData = await res.json();
                const m = activeRunData.metrics || {};
                document.getElementById("m-title").innerHTML = `<code>${esc(activeRunData.task_id)}</code> ${badge(m.status)}`;
                document.getElementById("m-sub").textContent = `playbook=${m.playbook || "-"} | duration=${m.duration_sec || 0}s | tokens=${Number((m.usage && m.usage.total_tokens) || 0).toLocaleString()} | est=$${Number(m.estimated_cost_usd || 0).toFixed(4)}`;
                const attachBtn = document.getElementById("m-copy-attach");
                attachBtn.onclick = () => copyText(m.takeover_cmd || activeRunData.attach_cmd, attachBtn);
                renderRunTab();
              }

              async function renderRunTab() {
                if (!activeRunData) return;
                const body = document.getElementById("m-body");
                const m = activeRunData.metrics || {};
                const issue = activeRunData.issue;

                if (activeTab === "overview") {
                  const ac = issue && issue.contract && issue.contract.acceptance_criteria ? issue.contract.acceptance_criteria : [];
                  body.innerHTML = `
                    <div class="kpi-grid">
                      <div class="card" style="margin:0;"><div class="muted">STATUS</div><div style="margin-top:6px;">${badge(m.status)}</div></div>
                      <div class="card" style="margin:0;"><div class="muted">LOOPS (VERIFY / REVIEW)</div><div class="kpi-val">${esc(m.verify_loops || 0)} / ${esc(m.review_loops || 0)}</div></div>
                      <div class="card" style="margin:0;"><div class="muted">TOKENS (CACHE HIT)</div><div class="kpi-val">${Number((m.usage && m.usage.total_tokens) || 0).toLocaleString()} <span class="muted">(${Math.round((m.cache_hit_ratio || 0) * 100)}%)</span></div></div>
                      <div class="card" style="margin:0;"><div class="muted">EST. COST</div><div class="kpi-val">$${Number(m.estimated_cost_usd || 0).toFixed(4)}</div></div>
                    </div>
                    ${issue && issue.pr_url ? `<div class="card"><strong>Pull Request:</strong> <a href="${esc(issue.pr_url)}" target="_blank">${esc(issue.pr_url)}</a></div>` : ""}
                    ${issue && issue.last_error ? `<div class="card"><strong>Last Error:</strong><pre class="log">${esc(issue.last_error)}</pre></div>` : ""}
                    ${issue && issue.contract ? `<div class="card">
                      <h3>Router Contract</h3>
                      <div><strong>done_if:</strong> ${esc(issue.contract.done_if)}</div>
                      <div style="margin-top:6px;"><strong>QA Demo:</strong> ${badge(issue.contract.needs_qa_demo ? "yes" : "no")} <span class="muted">${esc(issue.contract.qa_reason || "")}</span></div>
                      <h3 style="margin-top:12px;">Acceptance Criteria</h3>
                      <ul>${ac.map(a => `<li><strong>${esc(a.id)}</strong> (<code>${esc(a.verification_method)}</code>): ${esc(a.criterion)}</li>`).join("")}</ul>
                    </div>` : ""}
                  `;
                } else if (activeTab === "logs") {
                  const logs = activeRunData.logs || [];
                  if (!logs.length) { body.innerHTML = `<div class="muted">No log files for this run.</div>`; return; }
                  const defaultLog = logs.includes("pipeline.log") ? "pipeline.log" : logs[0];
                  body.innerHTML = `
                    <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
                      <select id="run-log-sel" onchange="loadRunLog()">${logs.map(l => `<option value="${esc(l)}" ${l===defaultLog?"selected":""}>${esc(l)}</option>`).join("")}</select>
                      <select id="run-log-lines" onchange="loadRunLog()">
                        <option value="400" selected>Last 400 lines</option>
                        <option value="1500">Last 1500 lines</option>
                        <option value="5000">Last 5000 lines</option>
                      </select>
                      <button class="pill-btn ${logMode==="structured"?"active":""}" onclick="setLogMode('structured')">Structured</button>
                      <button class="pill-btn ${logMode==="raw"?"active":""}" onclick="setLogMode('raw')">Raw</button>
                      <span class="muted">|</span>
                      <button class="pill-btn ${logFilter==="all"?"active":""}" onclick="setLogFilter('all')">All</button>
                      <button class="pill-btn ${logFilter==="conversation"?"active":""}" onclick="setLogFilter('conversation')">Conversation</button>
                      <button class="pill-btn ${logFilter==="tools"?"active":""}" onclick="setLogFilter('tools')">Tool calls</button>
                      <button class="pill-btn ${logFilter==="system"?"active":""}" onclick="setLogFilter('system')">System</button>
                      <button onclick="loadRunLog()">Reload</button>
                    </div>
                    <div id="run-log-container"><pre class="log">Loading...</pre></div>
                  `;
                  await loadRunLog();
                } else if (activeTab === "review") {
                  const arbs = activeRunData.arbitrage_reviews || [];
                  const raws = activeRunData.raw_reviews || [];
                  if (!arbs.length && !raws.length) { body.innerHTML = `<div class="muted">No review verdicts recorded yet.</div>`; return; }
                  body.innerHTML = arbs.map(a => {
                    const d = a.data;
                    const rulings = (d.ruled_findings || []).map(f => `<tr>
                      <td>${badge(f.verdict)}</td>
                      <td>${badge(f.severity)} / p:${esc(f.probability)} / r:${esc(f.risk)}</td>
                      <td><code>${esc(f.file)}</code><div class="muted">from ${esc(f.source_reviewer)}</div></td>
                      <td><strong>${esc(f.claim)}</strong><div class="muted">${esc(f.reasoning)}</div></td>
                    </tr>`).join("");
                    return `<div class="card">
                      <h3>${esc(a.file)} ${badge(d.approved ? "APPROVED" : "REJECTED")} <span class="muted">arbiter=${esc(d.arbiter || "-")}</span></h3>
                      <p>${esc(d.summary)}</p>
                      ${(d.verdicts || []).map(v => `<div style="margin:4px 0;">${badge(v.approved ? "APPROVED" : "REJECTED")} <strong>${esc(v.reviewer)}</strong>: ${esc(v.summary)}</div>`).join("")}
                      ${rulings ? `<h3 style="margin-top:12px;">Arbiter Rulings</h3><table><tr><th>Verdict</th><th>Sev / Prob / Risk</th><th>File</th><th>Claim &amp; Reasoning</th></tr>${rulings}</table>` : ""}
                    </div>`;
                  }).join("") + (raws.length ? `<div class="card"><h3>Raw Reviewer JSONs</h3>${raws.map(r => `<details style="margin-bottom:8px;"><summary><code>${esc(r.file)}</code> ${badge(r.data.approved ? "APPROVED" : "REJECTED")}</summary><pre class="log">${esc(JSON.stringify(r.data, null, 2))}</pre></details>`).join("")}</div>` : "");
                } else if (activeTab === "qa") {
                  const qas = activeRunData.qa || [];
                  if (!qas.length) { body.innerHTML = `<div class="muted">No QA recordings for this run yet.</div>`; return; }
                  body.innerHTML = qas.map(q => `
                    <div class="card">
                      <h3>${esc(q.kind === "before_repro" ? "Before Fix (Repro)" : "After Fix (Verified)")} - ${esc(q.report.scenario)} ${badge(q.report.passed ? "PASS" : "FAIL")}</h3>
                      <div class="media-grid">${q.videos.map(v => `<div><div class="muted">${esc(v.split("/").pop())}</div><video controls preload="metadata" src="${esc(v)}"></video></div>`).join("")}</div>
                      <div class="shots">${q.screenshots.map(s => `<a href="${esc(s)}" target="_blank"><img src="${esc(s)}" /></a>`).join("")}</div>
                    </div>
                  `).join("");
                } else if (activeTab === "costs") {
                  const sessions = activeRunData.sessions || [];
                  if (!sessions.length) { body.innerHTML = `<div class="muted">No per-stage session/cost records yet.</div>`; return; }
                  body.innerHTML = `<div class="card"><table>
                    <tr><th>Stage</th><th>Model</th><th>Tokens (In / Cached / Out)</th><th>Est. USD</th><th>Time</th><th>Takeover</th></tr>
                    ${sessions.map(s => {
                      const u = s.usage || {};
                      return `<tr>
                        <td><code>${esc(s.stage)}</code></td>
                        <td>${esc(s.backend)}:${esc(s.model || "-")}</td>
                        <td>${Number(u.total_tokens || 0).toLocaleString()} <span class="muted">(${Number(u.input_tokens || 0).toLocaleString()} / ${Number(u.cached_input_tokens || 0).toLocaleString()} / ${Number(u.output_tokens || 0).toLocaleString()})</span></td>
                        <td>$${Number(s.estimated_cost_usd || 0).toFixed(4)}</td>
                        <td>${esc(s.duration_sec)}s</td>
                        <td>${s.takeover_cmd ? `<button onclick='copyText(${JSON.stringify(s.takeover_cmd)}, this)'>Copy cmd</button>` : "-"}</td>
                      </tr>`;
                    }).join("")}
                  </table></div>`;
                } else if (activeTab === "artifacts") {
                  const arts = activeRunData.artifacts || [];
                  body.innerHTML = `
                    <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px;">
                      ${arts.map(a => `<button onclick='loadArtifact(${JSON.stringify(a.name)})'>${esc(a.name)} (${Math.round(a.size/1024)}KB)</button>`).join("")}
                    </div>
                    <pre class="log" id="art-pre">Select an artifact above to inspect.</pre>
                  `;
                }
              }

              function setLogMode(mode) {
                logMode = mode;
                renderRunTab();
              }

              function setLogFilter(filter) {
                logFilter = filter;
                renderRunTab();
              }

              function classifyLogEntry(stage, body) {
                const b = body.trim();
                if (b.startsWith("[AGENT]") || b.startsWith("msg:")) {
                  return { kind: "agent", group: "conversation", label: "AGENT", text: b.replace(/^(\\[AGENT\\]|msg:)\\s*/, "") };
                }
                if (b.startsWith("[THINKING]")) {
                  return { kind: "think", group: "conversation", label: "THINKING", text: b.replace(/^\\[THINKING\\]\\s*/, "") };
                }
                if (b.startsWith("[TOOL:EDIT]") || b.startsWith("file_change:")) {
                  return { kind: "edit", group: "tools", label: "TOOL:EDIT", text: b.replace(/^(\\[TOOL:EDIT\\]|file_change:)\\s*/, "") };
                }
                const cmdMatch = b.match(/^\\[TOOL:CMD exit=(\\d+)\\]\\s*([\\s\\S]*)$/) || b.match(/^cmd exit=(\\d+):\\s*([\\s\\S]*)$/);
                if (cmdMatch) {
                  const code = Number(cmdMatch[1]);
                  return { kind: code === 0 ? "tool" : "error", group: "tools", label: "TOOL:CMD exit=" + code, text: cmdMatch[2] };
                }
                if (b.startsWith("[TOOL:OUTPUT]")) {
                  return { kind: "error", group: "tools", label: "TOOL:OUTPUT", text: b.replace(/^\\[TOOL:OUTPUT\\]\\s*/, "") };
                }
                if (b.startsWith("[TOOL:MCP]") || b.startsWith("[TOOL:SEARCH]")) {
                  const m = b.match(/^\\[(TOOL:[A-Z]+)\\]\\s*([\\s\\S]*)$/);
                  return { kind: "tool", group: "tools", label: m ? m[1] : "TOOL", text: m ? m[2] : b };
                }
                if (b.startsWith("[ERROR]") || b.startsWith("ERROR:") || b.startsWith("TURN_FAILED:") || stage === "ERROR") {
                  return { kind: "error", group: "system", label: "ERROR", text: b.replace(/^\\[ERROR\\]\\s*/, "") };
                }
                return { kind: "sys", group: "system", label: stage || "SYS", text: b };
              }

              function parseLogEntries(raw) {
                const lines = (raw || "").split("\\n");
                const entries = [];
                const headerRe = /^\\[(\\d{2}:\\d{2}:\\d{2})\\]\\s+\\[([^\\]]+(?:\\[[^\\]]+\\])?)\\]\\s?(.*)$/;
                for (const line of lines) {
                  const m = line.match(headerRe);
                  if (m) {
                    entries.push({ time: m[1], stage: m[2], body: m[3] });
                  } else if (entries.length > 0) {
                    entries[entries.length - 1].body += "\\n" + line;
                  } else if (line.trim()) {
                    entries.push({ time: "", stage: "RAW", body: line });
                  }
                }
                return entries;
              }

              function renderRunLogText(text) {
                const container = document.getElementById("run-log-container");
                if (!container) return;
                if (logMode === "raw") {
                  container.innerHTML = `<pre class="log" id="run-log-pre">${esc(text)}</pre>`;
                  const pre = document.getElementById("run-log-pre");
                  if (pre) pre.scrollTop = pre.scrollHeight;
                  return;
                }
                const entries = parseLogEntries(text).map(e => ({ ...e, ...classifyLogEntry(e.stage, e.body) }));
                const filtered = entries.filter(e => logFilter === "all" || e.group === logFilter);
                if (!filtered.length) {
                  container.innerHTML = `<div class="muted" style="margin-top:8px;">No matching log entries for filter '${esc(logFilter)}'.</div>`;
                  return;
                }
                const kindBadge = { agent: "info", think: "badge", tool: "warn", edit: "ok", error: "err", sys: "badge" };
                container.innerHTML = `<div class="log-feed" id="run-log-feed">${filtered.map(e => `
                  <div class="log-entry kind-${esc(e.kind)}">
                    <div class="log-meta">
                      <span class="muted">${esc(e.time)}</span>
                      <span class="badge ${kindBadge[e.kind] || ""}">${esc(e.label)}</span>
                      <code class="muted">${esc(e.stage)}</code>
                    </div>
                    <pre class="log-body">${esc(e.text)}</pre>
                  </div>
                `).join("")}</div>`;
                const feed = document.getElementById("run-log-feed");
                if (feed) feed.scrollTop = feed.scrollHeight;
              }

              async function loadRunLog() {
                const sel = document.getElementById("run-log-sel");
                const linesSel = document.getElementById("run-log-lines");
                if (!sel || !activeRunId) return;
                const lines = linesSel ? linesSel.value : "400";
                const res = await fetch("/api/log?file=" + encodeURIComponent(activeRunId + "/" + sel.value) + "&lines=" + encodeURIComponent(lines));
                lastRunLogText = await res.text();
                renderRunLogText(lastRunLogText);
              }

              async function loadArtifact(name) {
                const res = await fetch("/api/artifact?id=" + encodeURIComponent(activeRunId) + "&file=" + encodeURIComponent(name));
                const pre = document.getElementById("art-pre");
                if (pre) pre.textContent = await res.text();
              }

              async function loadBotLog() {
                const res = await fetch("/api/log?file=bot.log&lines=160");
                const el = document.getElementById("bot-log-view");
                if (el) { el.textContent = await res.text(); el.scrollTop = el.scrollHeight; }
              }

              async function refreshAll() {
                const res = await fetch("/api/state");
                const data = await res.json();
                document.getElementById("side-status").textContent = "Updated " + data.generated_at.slice(11, 19) + "Z";

                const k = data.kpis;
                const kpiHtml = [
                  ["Runs", k.total_runs],
                  ["1st-Pass Verify", k.first_pass_rate + "%"],
                  ["Total Tokens", Number(k.total_tokens).toLocaleString()],
                  ["Cache Hit", k.cache_hit_pct + "%"],
                  ["Est. Cost", "$" + Number(k.estimated_cost_usd).toFixed(3)],
                  ["Clean / Edited", k.merged_clean + " / " + k.merged_edited]
                ].map(([l, v]) => `<div class="card" style="margin:0;"><div class="muted">${esc(l)}</div><div class="kpi-val">${esc(v)}</div></div>`).join("");
                document.getElementById("mini-kpis").innerHTML = kpiHtml;
                document.getElementById("full-kpis").innerHTML = kpiHtml;

                const cols = [
                  ["triage", "Triage / Info"],
                  ["ready", "Ready"],
                  ["in_progress", "In Progress"],
                  ["review", "Review / QA"],
                  ["blocked", "Blocked"],
                  ["done", "Merged"]
                ];
                document.getElementById("kanban-board").innerHTML = cols.map(([key, label]) => {
                  const items = (data.cards || []).filter(c => c.column === key);
                  return `<div class="col">
                    <div class="col-head"><span>${esc(label)}</span><span class="badge">${items.length}</span></div>
                    ${items.map(c => `<div class="run-card" onclick='openRun(${JSON.stringify(c.task_id)})'>
                      <div style="display:flex;justify-content:space-between;align-items:center;gap:6px;">
                        <strong><code>${esc(c.task_id)}</code></strong>
                        ${badge(c.status)}
                      </div>
                      <div class="muted" style="margin-top:6px;">${esc(c.playbook || "-")} ${c.needs_qa_demo ? "• QA" : ""} ${c.parent_issue ? "• Epic #" + esc(c.parent_issue) : ""} ${c.pilot ? "• PILOT" : ""}</div>
                      ${c.depends_on && c.depends_on.length ? `<div class="muted">deps: ${c.depends_on.map(d => "#" + esc(d)).join(", ")}</div>` : ""}
                      <div class="muted" style="margin-top:4px;">${c.total_tokens ? Number(c.total_tokens).toLocaleString() + " tok" : ""} ${c.estimated_cost_usd ? "• $" + Number(c.estimated_cost_usd).toFixed(3) : ""}</div>
                    </div>`).join("") || `<div class="muted" style="padding:8px;">Empty</div>`}
                  </div>`;
                }).join("");

                const fEntries = Object.entries(k.top_failures || {});
                document.getElementById("failures-table").innerHTML = fEntries.length
                  ? `<table><tr><th>Category</th><th>Count</th></tr>${fEntries.map(([c, n]) => `<tr><td>${badge(c)}</td><td>${esc(n)}</td></tr>`).join("")}</table>`
                  : `<div class="muted">No failures recorded.</div>`;

                document.getElementById("runs-table").innerHTML = data.runs.length
                  ? `<table><tr><th>Task</th><th>Status</th><th>Tokens</th><th>Est. Cost</th><th>Duration</th><th></th></tr>${data.runs.map(r => `<tr>
                      <td><code>${esc(r.task_id)}</code></td><td>${badge(r.status)}</td>
                      <td>${Number((r.usage && r.usage.total_tokens) || 0).toLocaleString()}</td>
                      <td>$${Number(r.estimated_cost_usd || 0).toFixed(4)}</td>
                      <td>${esc(r.duration_sec || 0)}s</td>
                      <td><button onclick='openRun(${JSON.stringify(r.task_id)})'>Inspect</button></td>
                    </tr>`).join("")}</table>`
                  : `<div class="muted">No runs yet.</div>`;

                document.getElementById("lessons-view").innerHTML = data.lessons.length
                  ? data.lessons.map(l => `<div style="margin-bottom:10px;border-bottom:1px solid var(--border);padding-bottom:8px;">${badge(l.recommended_lever)} <strong>${esc(l.pattern)}</strong><div class="muted">${esc(l.root_cause)}</div></div>`).join("")
                  : `<div class="muted">No lessons yet. Run <code>factory retro</code> after merging a PR.</div>`;

                document.getElementById("scout-view").innerHTML = data.scout && data.scout.findings && data.scout.findings.length
                  ? data.scout.findings.map(f => `<div style="margin-bottom:10px;border-bottom:1px solid var(--border);padding-bottom:8px;">${badge(f.category)} <strong>${esc(f.title)}</strong><div class="muted">${esc(f.evidence)}</div></div>`).join("")
                  : `<div class="muted">No scout proposals yet. Run <code>factory scout</code>.</div>`;

                if (activeView === "botlog") await loadBotLog();
                if (activeRunId && activeTab === "logs") await loadRunLog();
              }

              refreshAll();
              setInterval(refreshAll, 5000);
            </script>
          </body>
          </html>
        HTML
    end
  end
end
