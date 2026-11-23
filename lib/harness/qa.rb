require "fileutils"
require "json"
require "net/http"
require "open3"
require "socket"
require "timeout"
require "uri"
require_relative "qa_memory"

module Harness
  # Boots a project preview server, records mobile + desktop Playwright demo videos
  # and screenshots, verifies zero JS/HTTP 5xx/overflow errors, and optionally publishes
  # media evidence to an orphan GitHub branch for inline PR playback.
  class Qa
    EVIDENCE_BRANCH = "harness-evidence"

    def initialize(repo_root:, worktree_dir:, artifacts_dir:, logger:, memory: nil)
      @repo_root = File.expand_path(repo_root)
      @worktree_dir = File.expand_path(worktree_dir)
      @artifacts_dir = File.expand_path(artifacts_dir)
      @logger = logger
      @memory = memory || QaMemory.new(repo_root: @repo_root)
    end

    def plan_scenario(backend:, model: nil, reasoning_effort: nil, brief:, done_if:, diff: "", mode: :verify,
      previous_error: nil)
      schema_path = File.join(Harness::Paths::ROOT, "schemas", "qa-scenario.json")
      filename = mode == :repro ? "qa-repro-scenario.json" : "qa-scenario.json"
      out_file = File.join(@artifacts_dir, filename)

      mode_note = if mode == :repro
        "MODE: BUG REPRO FIRST. Write assertions for the EXPECTED FIXED behavior so that running this scenario BEFORE the fix fails cleanly on the bug, and running the EXACT SAME scenario AFTER the fix passes."
      else
        "MODE: POST-FIX DEMO & VERIFICATION. Write assertions verifying the implemented feature works cleanly end to end."
      end

      diff_section = if diff.to_s.strip.empty?
        "_No diff yet (pre-fix bug reproduction)._"
      else
        "```diff\n#{diff.byteslice(0, 30_000)}\n```"
      end

      retry_section = if previous_error && !previous_error.to_s.strip.empty?
        <<~RETRY

          ## Previous Scenario Attempt FAILED (Fix the scenario!)
          Your previous Playwright scenario failed with:
          ```
          #{previous_error.to_s.strip}
          ```
          Correct paths and selectors using the worktree and project QA map.
        RETRY
      else
        ""
      end

      app_map_section = load_app_map_section
      memory_section = @memory.format_prompt_section
      templates_section = load_baseline_templates_section

      prompt = <<~PROMPT
        You are the QA DEMO PLANNER for the target project (read-only).
        #{mode_note}
        Create a short, reliable Playwright QA scenario JSON in both mobile (390x844) and desktop (1280x800) viewports.

        Use the project's QA map, recorded scenarios and actual application code to find stable routes and selectors.
        Navigate through rendered links for dynamic identifiers. Assert the behavior named in the acceptance criteria.
        Use only disposable test data. Keep each screenshot and viewport name to letters, numbers, underscores and hyphens.
        Begin goto paths with a single slash. Include a screenshot at important points in the flow.
        #{retry_section}#{app_map_section}#{memory_section}#{templates_section}
        ## Task Brief
        #{brief.strip}

        ## Hard Stop Condition (`done_if`)
        #{done_if.strip}

        ## Git Diff
        #{diff_section}
      PROMPT

      backend.run(
        stage: "QA_PLANNER[#{mode}:#{backend.name}]",
        role: "qa",
        worktree_dir: @worktree_dir,
        prompt: prompt,
        output_file: out_file,
        sandbox: "read-only",
        model: model,
        reasoning_effort: reasoning_effort,
        output_schema: schema_path
      )

      out_file
    end

    def run_repro(scenario_path:, upload_evidence: false, task_id: nil)
      qa_dir = File.join(@artifacts_dir, "qa-repro")
      Harness::Paths.task!(task_id) if task_id
      report = execute_scenario(
        scenario_path: scenario_path,
        qa_dir: qa_dir,
        upload_evidence: upload_evidence,
        upload_subdir: task_id ? "#{task_id}/repro" : nil
      )

      reproduced = !report["passed"]
      report["reproduced"] = reproduced
      File.write(File.join(qa_dir, "qa-report.json"), JSON.pretty_generate(report))

      if reproduced
        @logger.info("QA_REPRO", "Bug reproduced BEFORE fix as expected (evidence in #{qa_dir})")
      else
        @logger.info("QA_REPRO", "Scenario unexpectedly PASSED before fix; worker must still verify root cause.")
      end

      report
    end

    def run(scenario_path:, upload_evidence: false, task_id: nil)
      qa_dir = File.join(@artifacts_dir, "qa")
      Harness::Paths.task!(task_id) if task_id
      report = execute_scenario(
        scenario_path: scenario_path,
        qa_dir: qa_dir,
        upload_evidence: upload_evidence,
        upload_subdir: task_id
      )
      @memory.record_run!(scenario_path: scenario_path, report: report)

      unless report["passed"]
        failed = Array(report["viewports"]).reject { |v| v["passed"] }.map do |v|
          "#{v["viewport"]}: #{v["failed_reason"] || "errors/overflow detected"}"
        end
        raise QaError.new("QA demo failed (#{failed.join("; ")}). See #{qa_dir}", report: report)
      end

      @logger.info("QA", "PASSED mobile + desktop demo recording in #{qa_dir}")
      report
    end

    def self.format_repro_feedback(repro_report)
      return "" unless repro_report

      if repro_report["reproduced"]
        failures = Array(repro_report["viewports"]).reject { |v| v["passed"] }.map do |v|
          details = [ v["failed_reason"] ]
          details << "page_errors=#{v["page_errors"].size}" if Array(v["page_errors"]).any?
          details << "http_5xx=#{v["http_5xx"].size}" if Array(v["http_5xx"]).any?
          details << "overflow=#{v["horizontal_overflow"].size}" if Array(v["horizontal_overflow"]).any?
          "- `#{v["viewport"]}`: #{details.compact.join(", ")} (video: `#{v["video_path"]}`)"
        end.join("\n")

        <<~MD
          ## Pre-Fix Bug Reproduction (CONFIRMED FAILING)
          The exact QA scenario `#{repro_report["scenario"]}` was executed BEFORE your edits and reproduced the failure:
          #{failures}

          Your fix must make this exact scenario pass (along with a permanent regression check).
        MD
      else
        "## Pre-Fix Bug Reproduction Note\nThe automated browser scenario `#{repro_report["scenario"]}` passed before your edits; verify the bug directly with a failing project check before changing production code."
      end
    end

    def self.format_pr_section(report, repro_report: nil)
      return "" unless report

      repro_block = if repro_report
        repro_status = repro_report["reproduced"] ? "**REPRODUCED (failed as expected before fix)**" : "**NOT REPRODUCED IN BROWSER**"
        repro_uploaded = repro_report["uploaded_urls"] || {}
        repro_links = Array(repro_report["viewports"]).filter_map do |vp|
          file = vp["video_path"] ? File.basename(vp["video_path"]) : nil
          next unless file

          url = repro_uploaded[file]
          url ? "- Before (`#{vp["viewport"]}`): [#{file}](#{url})" : "- Before (`#{vp["viewport"]}`): `#{vp["video_path"]}`"
        end.join("\n")

        <<~REPRO
          ### Before Fix (Bug Reproduction)
          - Scenario `#{repro_report["scenario"]}`: #{repro_status}
          #{repro_links}

        REPRO
      else
        ""
      end

      status = report["passed"] ? "**PASSED**" : "**FAILED**"
      uploaded = report["uploaded_urls"] || {}

      rows = Array(report["viewports"]).map do |vp|
        vp_status = vp["passed"] ? "PASS" : "FAIL"
        video_file = vp["video_path"] ? File.basename(vp["video_path"]) : "none"
        video_url = uploaded[video_file]
        video_cell = video_url ? "[#{video_file}](#{video_url})" : "`#{vp["video_path"]}`"

        "| `#{vp["viewport"]}` (#{vp["width"]}x#{vp["height"]}) | #{vp_status} | #{vp["page_errors"].size} | " \
        "#{vp["http_5xx"].size} | #{vp["horizontal_overflow"].size} | #{video_cell} |"
      end.join("\n")

      media_embeds = []
      Array(report["viewports"]).each do |vp|
        gif_file = vp["gif_path"] ? File.basename(vp["gif_path"]) : nil
        video_file = vp["video_path"] ? File.basename(vp["video_path"]) : nil
        if gif_file && uploaded[gif_file]
          hd_link = video_file && uploaded[video_file] ? " ([HD MP4](#{uploaded[video_file]}))" : ""
          media_embeds << "#### Demo (`#{vp["viewport"]}`)#{hd_link}\n![#{gif_file}](#{uploaded[gif_file]})"
        elsif video_file && uploaded[video_file]
          media_embeds << "#### Demo Video (`#{vp["viewport"]}`)\n[#{video_file}](#{uploaded[video_file]})"
        end
        Array(vp["screenshots"]).each do |shot_path|
          shot_file = File.basename(shot_path)
          if uploaded[shot_file]
            media_embeds << "![#{shot_file}](#{uploaded[shot_file]})"
          end
        end
      end

      embeds_block = media_embeds.empty? ? "" : "\n#{media_embeds.join("\n\n")}\n"

      <<~MD
        ## QA Demo & Evidence
        #{repro_block}### After Fix (Verified)
        - Scenario `#{report["scenario"]}`: #{status}

        | Viewport | Status | JS Errors | HTTP 5xx | Overflow | Demo Video |
        | --- | --- | --- | --- | --- | --- |
        #{rows}
        #{embeds_block}
      MD
    end

    private
    def load_app_map_section
      path = File.join(Harness::Paths.profile(@repo_root), "qa", "app-map.md")
      return "" unless File.exist?(path)

      "\n## Verified QA Application Map (`profile qa/app-map.md`)\n#{File.read(path).strip}\n"
    end

    def load_baseline_templates_section
      qa_dir = File.join(Harness::Paths.profile(@repo_root), "qa")
      return "" unless Dir.exist?(qa_dir)

      files = Dir.glob(File.join(qa_dir, "*.json")).sort
      return "" if files.empty?

      blocks = files.map do |file|
        "### Template: `profile qa/#{File.basename(file)}`\n```json\n#{File.read(file).strip}\n```"
      end.join("\n\n")

      "\n## Verified Baseline QA Templates (reuse & extend these instead of inventing selectors)\n#{blocks}\n"
    end

    def execute_scenario(scenario_path:, qa_dir:, upload_evidence:, upload_subdir:)
      FileUtils.mkdir_p(qa_dir)

      port = pick_free_port
      env = { "PORT" => port.to_s }

      server_log = File.join(qa_dir, "preview.log")
      pid = start_preview(env, port, server_log)

      begin
        wait_for_server!(port, pid, server_log)
        report = run_playwright_recorder(env, port, scenario_path, qa_dir)
      ensure
        stop_preview(pid)
      end

      if upload_evidence && upload_subdir && (report["passed"] || upload_subdir.end_with?("/repro"))
        report["uploaded_urls"] = publish_evidence_branch(qa_dir, upload_subdir)
        File.write(File.join(qa_dir, "qa-report.json"), JSON.pretty_generate(report))
      end

      report
    end
    def pick_free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    def start_preview(env, port, server_log)
      hook = File.join(Harness::Paths.profile(@repo_root), "hooks", "serve")
      raise QaError, "Set up an executable preview hook at #{hook}" unless File.executable?(hook)

      @logger.info("QA", "Starting preview on 127.0.0.1:#{port}")
      spawn(env, [hook, hook], chdir: @worktree_dir, out: server_log, err: [:child, :out], pgroup: true)
    end

    def wait_for_server!(port, pid, server_log, timeout_sec: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
      uri = URI("http://127.0.0.1:#{port}/")

      loop do
        begin
          response = Net::HTTP.get_response(uri)
          return if response.code.to_i < 500
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::ReadTimeout
          nil
        end

        if Process.waitpid(pid, Process::WNOHANG)
          log_tail = File.exist?(server_log) ? File.read(server_log).lines.last(30).join : ""
          raise QaError.new("Preview server exited before becoming ready:\n#{log_tail}")
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise QaError.new("Timed out waiting for Preview server on port #{port}")
        end

        sleep(0.3)
      end
    end

    def stop_preview(pid)
      return unless pid

      Process.kill("TERM", -pid)
      Timeout.timeout(5) { Process.waitpid(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def run_playwright_recorder(env, port, scenario_path, qa_dir)
      script = File.join(Harness::Paths::ROOT, "scripts", "record_qa.py")
      cmd = [
        ENV.fetch("FACTORY_PYTHON", "python3"), script,
        "--base-url", "http://127.0.0.1:#{port}",
        "--scenario", File.expand_path(scenario_path),
        "--out-dir", qa_dir
      ]

      @logger.info("QA", "Recording Playwright QA demo: #{scenario_path}")
      report_path = File.join(qa_dir, "qa-report.json")
      FileUtils.rm_f(report_path)
      out, status = Open3.capture2e(env, *cmd, chdir: @worktree_dir)
      File.write(File.join(qa_dir, "recorder.log"), out)

      unless [0, 1].include?(status.exitstatus) && File.exist?(report_path)
        raise QaError.new("Playwright recorder did not produce qa-report.json:\n#{out}")
      end

      JSON.parse(File.read(report_path))
    end

    def publish_evidence_branch(qa_dir, task_id)
      remote_url, st = Open3.capture2e("git", "remote", "get-url", "origin", chdir: @repo_root)
      return {} unless st.success?

      slug_match = remote_url.strip.match(%r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z})
      return {} unless slug_match

      repo_slug = slug_match[1]
      report = JSON.parse(File.read(File.join(qa_dir, "qa-report.json")))
      media_files = report.fetch("viewports").flat_map do |vp|
        [vp["video_path"], vp["webm_path"], vp["gif_path"], *vp["screenshots"]]
      end.compact.uniq
      return {} if media_files.empty?

      tmp_wt = File.join(Harness::Paths.profile(@repo_root), "worktrees", ".evidence-upload")
      raise QaError, "Evidence worktree is already in use" if File.exist?(tmp_wt)
      Open3.capture2e("git", "worktree", "prune", chdir: @repo_root)
      Open3.capture2e("git", "fetch", "origin", EVIDENCE_BRANCH, chdir: @repo_root)

      owned_worktree = false
      _, has_remote = Open3.capture2e("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{EVIDENCE_BRANCH}", chdir: @repo_root)
      if has_remote.success?
        run_checked({}, "git", "worktree", "add", "-B", EVIDENCE_BRANCH, tmp_wt, "origin/#{EVIDENCE_BRANCH}", chdir: @repo_root)
      else
        run_checked({}, "git", "worktree", "add", "--detach", tmp_wt, chdir: @repo_root)
        owned_worktree = true
        run_checked({}, "git", "checkout", "--orphan", EVIDENCE_BRANCH, chdir: tmp_wt)
        Open3.capture2e("git", "rm", "-rf", "--quiet", ".", chdir: tmp_wt)
      end

      owned_worktree = true
      dest_dir = File.join(tmp_wt, task_id)
      FileUtils.mkdir_p(dest_dir)
      urls = {}

      media_files.each do |file|
        basename = File.basename(file)
        FileUtils.cp(file, File.join(dest_dir, basename))
        # Use github.com/blob/...?raw=true so links work on both private and public GitHub repos.
        urls[basename] = "https://github.com/#{repo_slug}/blob/#{EVIDENCE_BRANCH}/#{task_id}/#{basename}?raw=true"
      end

      run_checked({}, "git", "add", task_id, chdir: tmp_wt)
      _, diff_st = Open3.capture2e("git", "diff", "--cached", "--quiet", chdir: tmp_wt)
      unless diff_st.success?
        run_checked({}, "git", "commit", "-m", "evidence(#{task_id}): upload QA videos and screenshots", chdir: tmp_wt)
      end
      run_checked({}, "git", "push", "-u", "origin", EVIDENCE_BRANCH, chdir: tmp_wt)
      @logger.info("QA", "Uploaded #{urls.size} evidence file(s) to branch #{EVIDENCE_BRANCH}")
      urls
    ensure
      if owned_worktree
        Open3.capture2e("git", "worktree", "remove", "--force", tmp_wt, chdir: @repo_root)
      end
    end

    def run_checked(env, *cmd, chdir:)
      out, status = Open3.capture2e(env, *cmd, chdir: chdir)
      raise QaError.new("Command failed (#{cmd.join(" ")}):\n#{out}") unless status.success?

      out
    end
  end
end
