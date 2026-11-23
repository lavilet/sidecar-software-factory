require "json"
require "time"
require_relative "checkpoint"

module Harness
  Config = Data.define(
    :task_id,
    :playbook,
    :brief,
    :done_if,
    :base_branch,
    :backend,
    :model,
    :architect_spec,
    :worker_spec,
    :reviewer_specs,
    :qa_spec,
    :max_verify_loops,
    :max_review_loops,
    :skip_architect,
    :skip_review,
    :run_qa,
    :qa_scenario,
    :upload_evidence,
    :open_pr,
    :push_only,
    :dry_run
  )

  class Runner
    def initialize(config, repo_root: Dir.pwd, backend: nil, architect_backend: nil,
      worker_backend: nil, qa_backend: nil, reviewers: nil, arbiter: nil, verifier: nil, handoff: nil, qa: nil,
      fresh: false)
      @config = config
      @fresh = fresh
      @repo_root = File.expand_path(repo_root)
      @config_file = ConfigFile.load(@repo_root)
      @workspace = Workspace.new(
        repo_root: @repo_root,
        task_id: config.task_id,
        base_branch: config.base_branch
      )
      @logger = Logger.new(@workspace.artifact_path("pipeline.log"))
      @telemetry = Telemetry.new(@workspace.telemetry_path)
      @sessions = SessionStore.new(artifacts_dir: @workspace.artifacts_dir)
      @checkpoint = Checkpoint.new(artifacts_dir: @workspace.artifacts_dir)
      @cost_estimator = CostEstimator.new(config_file: @config_file)
      @stage_mutex = Mutex.new
      @stage_metrics = []
      @prompts = Prompts.new(repo_root: @repo_root)

      @architect_spec = Backends.parse_spec(config.architect_spec || config.backend, default_model: config.model)
      @worker_spec = Backends.parse_spec(config.worker_spec || config.backend, default_model: config.model)
      @qa_spec = Backends.parse_spec(config.qa_spec || @config_file.role("qa"), default_model: config.model)

      @architect_backend = architect_backend || backend ||
        Backends.build(@architect_spec.backend, logger: @logger, repo_root: @repo_root)
      @worker_backend = worker_backend || backend ||
        Backends.build(@worker_spec.backend, logger: @logger, repo_root: @repo_root)
      @qa_backend = qa_backend || backend ||
        Backends.build(@qa_spec.backend, logger: @logger, repo_root: @repo_root)

      @reviewer_entries = build_reviewer_entries(reviewers: reviewers, fallback_backend: backend)
      @arbiter_entry = build_arbiter_entry(arbiter: arbiter, fallback_backend: backend)
      @arbitrage_reviewer = ArbitrageReviewer.new(
        reviewers: @reviewer_entries,
        arbiter: @arbiter_entry,
        repo_root: @repo_root,
        workspace: @workspace,
        logger: @logger,
        prompts: @prompts,
        on_stage_result: method(:record_stage_result)
      )

      @verifier = verifier || Verifier.new(
        repo_root: @repo_root,
        workspace: @workspace,
        logger: @logger
      )
      @handoff = handoff || Handoff.new(config: @config, workspace: @workspace, logger: @logger)
      @qa = qa || Qa.new(
        repo_root: @repo_root,
        worktree_dir: @workspace.worktree_dir,
        artifacts_dir: @workspace.artifacts_dir,
        logger: @logger
      )
    end

    def run
      File.open(@workspace.artifact_path("run.lock"), "w") do |lock|
        raise Error, "Task #{@config.task_id} is already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        run_pipeline
      end
    end

    private

    def run_pipeline
      started_at = Time.now.utc.iso8601
      started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = "error"
      verify_loops = 0
      review_loops = 0
      review_disagreements = 0
      failure_categories = []
      architecture_violations_count = 0
      pr_url = nil

      reviewer_labels = @reviewer_entries.map { |entry| entry[:label] }
      @logger.info(
        "INIT",
        "Starting task=#{@config.task_id} playbook=#{@config.playbook} " \
        "architect=#{@architect_backend.name} worker=#{@worker_backend.name} " \
        "reviewers=[#{reviewer_labels.join(", ")}]"
      )
      @workspace.prepare!
      File.write(@workspace.artifact_path("metrics.json"), JSON.pretty_generate(
        task_id: @config.task_id,
        playbook: @config.playbook,
        reviewers: reviewer_labels,
        status: "running",
        started_at: started_at,
        verify_loops: 0,
        review_loops: 0
      ))

      if @config.dry_run
        status, verify_loops = run_dry_run(failure_categories)
        return status
      end

      profile = Harness::Paths.profile(@repo_root)
      inputs = %w[hooks rules playbooks qa config.toml protected-paths.txt].flat_map do |entry|
        dir = File.join(profile, entry)
        File.directory?(dir) ? Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }.sort : [dir]
      end
      contract = [@config.brief, @config.done_if, @config.base_branch, @config.playbook, @config.reviewer_specs, @config.run_qa]
      inputs << @config.qa_scenario if @config.qa_scenario
      contract.concat(inputs.map { |path| [path, Digest::SHA256.file(path).hexdigest] })
      signature = Digest::SHA256.hexdigest(JSON.generate(contract))
      @fresh ||= @checkpoint.get("contract") != signature
      if @fresh
        @checkpoint.clear!
        @logger.info("RESUME", "Fresh run requested (--fresh): cleared saved checkpoint")
      elsif @config.playbook == "babysit-pr"
        # New human PR feedback requires running Worker, Verify, QA, and Review again.
        @checkpoint.save(
          verified_fingerprint: nil,
          qa_fingerprint: nil,
          qa_report: nil,
          review_approved_fingerprint: nil,
          review_result: nil,
          pending_review_feedback: nil,
          previous_review: nil
        )
      end

      @checkpoint.save(contract: signature)
      sync_babysit_branch_before_worker! if @config.playbook == "babysit-pr"
      @pre_worker_head = @workspace.head_sha

      plan = resolve_architect_plan
      repro_scenario_path = nil
      repro_report = nil
      initial_feedback = nil

      if @config.run_qa && @config.playbook == "bugfix"
        repro_scenario_path, repro_report = resolve_bug_repro_stage
        initial_feedback = Qa.format_repro_feedback(repro_report)
      end

      saved_review_feedback = @checkpoint.get("pending_review_feedback")
      if saved_review_feedback && !saved_review_feedback.to_s.strip.empty?
        @logger.info("RESUME", "Resuming with saved review feedback from previous attempt")
        initial_feedback = saved_review_feedback
      end

      review_result = nil
      qa_report = nil
      previous_review = @checkpoint.get("previous_review")

      current_fp = @workspace.state_fingerprint
      if !@config.skip_review &&
         @config.playbook != "babysit-pr" &&
         @checkpoint.get("review_approved_fingerprint") == current_fp &&
         (!@config.run_qa || @checkpoint.get("qa_fingerprint") == current_fp) &&
         @checkpoint.get("review_result")
        @logger.info("RESUME", "Arbitrage review already approved for current worktree snapshot (#{current_fp[0, 10]}); skipping to HANDOFF")
        review_result = @checkpoint.get("review_result")
        qa_report = @checkpoint.get("qa_report")
      elsif @config.skip_review
        verify_loops += run_or_resume_worker_and_verify(
          plan: plan,
          feedback: initial_feedback,
          round: 1,
          failure_categories: failure_categories
        )
        qa_report = @config.run_qa ? resolve_qa_stage(repro_scenario_path: repro_scenario_path) : nil
      else
        @config.max_review_loops.times do |index|
          round = index + 1
          @logger.info("LOOP", "=== Review round #{round}/#{@config.max_review_loops} ===")

          feedback = round == 1 ? initial_feedback : @prompts.format_review_feedback(review_result)
          verify_loops += run_or_resume_worker_and_verify(
            plan: plan,
            feedback: feedback,
            round: round,
            failure_categories: failure_categories
          )

          # Record mobile + desktop QA demo BEFORE Arbitrage Review so reviewers see actual video/screenshot proof.
          qa_report = @config.run_qa ? resolve_qa_stage(repro_scenario_path: repro_scenario_path) : nil

          review_loops += 1
          review_result = @arbitrage_reviewer.call(
            brief: @config.brief,
            done_if: @config.done_if,
            plan: plan,
            base_branch: @config.base_branch,
            round: round,
            qa_report: qa_report,
            repro_report: repro_report,
            previous_review: previous_review
          )
          architecture_violations_count += Array(review_result["architecture_violations"]).size
          review_disagreements += 1 if review_result["disagreement"]

          if review_result["approved"] == true
            @checkpoint.save(
              review_approved_fingerprint: @workspace.state_fingerprint,
              review_result: review_result,
              pending_review_feedback: nil,
              previous_review: nil
            )
            @logger.info("REVIEW", "ARBITRAGE APPROVED on round #{round}: #{review_result["summary"]}")
            break
          end

          if round == @config.max_review_loops && can_escalate_to_draft_pr?(review_result)
            review_result = review_result.merge("escalated_with_warnings" => true)
            @checkpoint.save(
              review_approved_fingerprint: @workspace.state_fingerprint,
              review_result: review_result,
              pending_review_feedback: nil,
              previous_review: nil
            )
            @logger.info(
              "REVIEW",
              "ARBITRAGE ESCALATED TO DRAFT PR WITH WARNINGS on round #{round}: " \
              "split verdict with 0 architecture violations and only medium/low residual finding(s)"
            )
            break
          end

          previous_review = review_result
          @checkpoint.save(
            review_approved_fingerprint: nil,
            review_result: nil,
            pending_review_feedback: @prompts.format_review_feedback(review_result),
            previous_review: review_result
          )
          @logger.info(
            "REVIEW",
            "ARBITRAGE REJECTED on round #{round}: disagreement=#{review_result["disagreement"]} " \
            "violations=#{Array(review_result["architecture_violations"]).size} " \
            "blockers=#{Array(review_result["blocking_issues"]).size} done_if_met=#{review_result["done_if_met"]}"
          )

          if round == @config.max_review_loops
            status = "review_blocked"
            raise ReviewError.new(
              "Arbitrage review rejected after #{@config.max_review_loops} round(s). See #{@workspace.artifacts_dir}",
              review: review_result
            )
          end
        end
      end

      if @config.open_pr || @config.push_only
        sync = @workspace.sync_with_base!(logger: @logger)
        raise CommandError, "Resolve the rebase conflict and retry: #{sync[:error]}" if sync[:status] == :conflict
        if sync[:status] == :rebased
          check = @verifier.call(label: "post-rebase")
          verify_loops += 1
          unless check.ok
            failure_categories << check.category
            verify_loops += run_worker_and_verify(plan: plan, feedback: format_verify_feedback("post-rebase", check),
              round: review_loops + 1, failure_categories: failure_categories)
          end
          qa_report = resolve_qa_stage(repro_scenario_path: repro_scenario_path) if @config.run_qa
          unless @config.skip_review
            review_loops += 1
            review_result = @arbitrage_reviewer.call(brief: @config.brief, done_if: @config.done_if, plan: plan,
              base_branch: @config.base_branch, round: review_loops, qa_report: qa_report, repro_report: repro_report)
            unless review_result["approved"]
              @checkpoint.save(pending_review_feedback: @prompts.format_review_feedback(review_result))
              raise ReviewError.new("Rebased candidate requires review fixes", review: review_result)
            end
          end
        end
      end

      pr_url = @handoff.call(plan: plan, review: review_result, qa_report: qa_report, repro_report: repro_report)
      status = if pr_url
        "pr_opened"
      elsif @config.push_only
        "pr_updated"
      else
        "verified"
      end
      @logger.info("DONE", "Task #{@config.task_id} finished with status=#{status}")
      status
    rescue VerificationError
      status = "verify_blocked"
      raise
    rescue QaError
      status = "qa_failed"
      raise
    ensure
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_clock).round(1)
      changed = Dir.exist?(@workspace.worktree_dir) ? @workspace.changed_files : []
      protected_hits = Dir.exist?(@workspace.worktree_dir) ? @workspace.protected_files_touched : []
      head = Dir.exist?(@workspace.worktree_dir) ? @workspace.head_sha : nil
      totals = CostEstimator.merge_usage(@stage_metrics.map { |m| m[:usage] })
      total_cost = @stage_metrics.sum { |m| m[:estimated_cost_usd].to_f }.round(5)
      budget_exceeded = totals["total_tokens"] > @config_file.max_tokens_per_run ||
        total_cost > @config_file.max_usd_per_run
      latest_worker = @sessions.latest_for(role: "worker")

      event = {
        task_id: @config.task_id,
        architect_backend: @architect_backend.name,
        worker_backend: @worker_backend.name,
        reviewers: @reviewer_entries.map { |entry| entry[:label] },
        model: @config.model,
        playbook: @config.playbook,
        base_branch: @config.base_branch,
        dry_run: @config.dry_run,
        status: status,
        started_at: started_at,
        finished_at: Time.now.utc.iso8601,
        duration_sec: duration,
        verify_loops: verify_loops,
        review_loops: review_loops,
        review_disagreements: review_disagreements,
        review_escalated: review_result.is_a?(Hash) && review_result["escalated_with_warnings"] == true,
        failure_categories: failure_categories,
        architecture_violations_count: architecture_violations_count,
        changed_files_count: changed.size,
        protected_files_touched: protected_hits,
        usage: totals,
        cache_hit_ratio: CostEstimator.cache_hit_ratio(totals),
        estimated_cost_usd: total_cost,
        budget_exceeded: budget_exceeded,
        latest_worker_session_id: latest_worker && latest_worker["session_id"],
        takeover_cmd: latest_worker && latest_worker["takeover_cmd"],
        head_sha: head,
        pr_url: pr_url,
        worktree_dir: @workspace.worktree_dir,
        artifacts_dir: @workspace.artifacts_dir
      }

      File.write(@workspace.artifact_path("metrics.json"), JSON.pretty_generate(event))
      @telemetry.record(event)
    end

    private
    # Escalates to a Draft PR with explicit human-review warnings instead of hard-blocking
    # when deterministic verification is green, there are zero architecture violations,
    # at least one independent reviewer approved (split verdict), and every residual finding
    # is medium or low severity/risk.
    def can_escalate_to_draft_pr?(review)
      return false unless @config.open_pr && review.is_a?(Hash) && review["done_if_met"]
      return false unless Array(review["architecture_violations"]).empty?

      verdicts = Array(review["verdicts"])
      return false unless verdicts.any? { |v| v["approved"] == true }

      blockers = Array(review["blocking_issues"])
      return false if blockers.empty?

      blockers.none? do |issue|
        %w[ critical high ].include?(issue["severity"].to_s.downcase) ||
          %w[ critical high ].include?(issue["risk"].to_s.downcase)
      end
    end

    def build_arbiter_entry(arbiter:, fallback_backend:)
      return nil if arbiter == false
      return arbiter if arbiter.is_a?(Hash)

      raw_spec = @config_file.role("arbiter")
      return nil if raw_spec.nil? || raw_spec.strip.empty?

      parsed = Backends.parse_spec(raw_spec, default_model: @config.model)
      instance = fallback_backend || Backends.build(parsed.backend, logger: @logger, repo_root: @repo_root)
      label = parsed.model ? "#{parsed.backend}:#{parsed.model}" : parsed.backend
      { label: label, backend: instance, model: parsed.model, effort: @config_file.effort("arbiter") }
    end

    def build_reviewer_entries(reviewers:, fallback_backend:)
      return reviewers if reviewers && !reviewers.empty?

      specs = Array(@config.reviewer_specs).reject { |item| item.to_s.strip.empty? }
      specs = [ @config.backend ] if specs.empty?

      specs.map do |raw_spec|
        parsed = Backends.parse_spec(raw_spec, default_model: @config.model)
        instance = fallback_backend || Backends.build(parsed.backend, logger: @logger, repo_root: @repo_root)
        label = parsed.model ? "#{parsed.backend}:#{parsed.model}" : parsed.backend
        { label: label, backend: instance, model: parsed.model, effort: @config_file.effort("reviewer") }
      end
    end

    def run_dry_run(failure_categories)
      architect_prompt = @prompts.architect(
        brief: @config.brief,
        done_if: @config.done_if,
        playbook_name: @config.playbook
      )
      worker_prompt = @prompts.worker(
        brief: @config.brief,
        done_if: @config.done_if,
        playbook_name: @config.playbook,
        plan: "_Dry run placeholder plan_"
      )
      reviewer_prompt = @prompts.reviewer(
        brief: @config.brief,
        done_if: @config.done_if,
        plan: "_Dry run placeholder plan_",
        changed_files: @workspace.changed_files,
        diff: @workspace.full_diff,
        base_branch: @config.base_branch
      )

      File.write(@workspace.artifact_path("architect-prompt.md"), architect_prompt)
      File.write(@workspace.artifact_path("worker-prompt-r1.md"), worker_prompt)
      File.write(@workspace.artifact_path("reviewer-prompt-r1.md"), reviewer_prompt)
      @logger.info("DRY_RUN", "Wrote stage prompts to #{@workspace.artifacts_dir}")

      result = @verifier.call(label: "dry-run")
      unless result.ok
        failure_categories << result.category
        raise VerificationError.new(
          "Verification failed during dry-run (category=#{result.category})",
          category: result.category,
          exit_code: result.exit_code,
          output: result.output
        )
      end

      @handoff.call(plan: "_Dry run placeholder plan_", review: nil)
      [ "dry_run_ok", 1 ]
    end

    def run_bug_repro_stage
      scenario_path = if @config.qa_scenario && !@config.qa_scenario.empty?
        @config.qa_scenario
      else
        @qa.plan_scenario(
          backend: @qa_backend,
          model: @qa_spec.model,
          reasoning_effort: @config_file.effort("qa"),
          brief: @config.brief,
          done_if: @config.done_if,
          diff: "",
          mode: :repro
        )
      end

      report = @qa.run_repro(
        scenario_path: scenario_path,
        upload_evidence: @config.upload_evidence,
        task_id: @config.task_id
      )
      [ scenario_path, report ]
    end

    def run_qa_stage(repro_scenario_path: nil, replay_scenario_path: nil)
      explicit_scenario = if repro_scenario_path && !repro_scenario_path.empty?
        repro_scenario_path
      elsif @config.qa_scenario && !@config.qa_scenario.empty?
        @config.qa_scenario
      end

      scenario_path = explicit_scenario || replay_scenario_path || @qa.plan_scenario(
        backend: @qa_backend,
        model: @qa_spec.model,
        reasoning_effort: @config_file.effort("qa"),
        brief: @config.brief,
        done_if: @config.done_if,
        diff: @workspace.full_diff,
        mode: :verify
      )

      report = @qa.run(
        scenario_path: scenario_path,
        upload_evidence: @config.upload_evidence,
        task_id: @config.task_id
      )
      [ scenario_path, report ]
    rescue QaError => error
      raise unless explicit_scenario.nil? && recoverable_qa_scenario_error?(error)

      @logger.info("QA", "Planned scenario failed without app crash (#{error.message}); replanning QA scenario once...")
      retry_path = @qa.plan_scenario(
        backend: @qa_backend,
        model: @qa_spec.model,
        reasoning_effort: @config_file.effort("qa"),
        brief: @config.brief,
        done_if: @config.done_if,
        diff: @workspace.full_diff,
        mode: :verify,
        previous_error: error.message
      )
      report = @qa.run(
        scenario_path: retry_path,
        upload_evidence: @config.upload_evidence,
        task_id: @config.task_id
      )
      [ retry_path, report ]
    end

    def recoverable_qa_scenario_error?(error)
      report = error.report
      return false unless report.is_a?(Hash)

      viewports = Array(report["viewports"])
      return false if viewports.empty?

      viewports.all? do |vp|
        Array(vp["http_5xx"]).empty? &&
          Array(vp["page_errors"]).empty? &&
          Array(vp["horizontal_overflow"]).empty?
      end
    end

    def record_stage_result(stage:, role:, backend:, model:, result:)
      usage = result.usage || CostEstimator.empty_usage
      cost = @cost_estimator.estimate_usd(model: model, usage: usage)

      @stage_mutex.synchronize do
        @stage_metrics << { stage: stage, role: role, usage: usage, estimated_cost_usd: cost }
        @sessions.record(
          stage: stage,
          role: role,
          backend: backend,
          model: model,
          session_id: result.session_id,
          worktree_dir: @workspace.worktree_dir,
          duration_sec: result.duration_sec,
          usage: usage,
          estimated_cost_usd: cost
        )
      end
    end

    def sync_babysit_branch_before_worker!
      sync = @workspace.sync_with_base!(logger: @logger)
      case sync[:status]
      when :up_to_date
        nil
      when :rebased
        @logger.info("SYNC", "Rebased babysit-pr worktree onto latest #{sync[:base_ref]} before invoking WORKER")
      when :conflict
        raise CommandError,
          "Auto-rebase onto #{sync[:base_ref]} failed before WORKER due to merge conflicts. " \
          "Resolve conflicts in #{@workspace.worktree_dir} and retry:\n#{sync[:error]}"
      end
    end

    def resolve_architect_plan
      return nil if @config.skip_architect

      plan_file = @workspace.artifact_path("plan.md")
      if !@fresh && File.exist?(plan_file)
        existing = File.read(plan_file).to_s.strip
        unless existing.empty?
          @logger.info("RESUME", "Reusing existing Architect plan from plan.md (skipping ARCHITECT)")
          return existing
        end
      end

      plan = run_architect_stage
      @checkpoint.save(architect_done: true)
      plan
    end

    def resolve_bug_repro_stage
      if !@fresh && @checkpoint.get("bug_repro_done") && @checkpoint.get("repro_report")
        scenario_path = @checkpoint.get("repro_scenario_path")
        if scenario_path.nil? || File.exist?(scenario_path)
          @logger.info("RESUME", "Reusing existing bug reproduction report (skipping pre-fix QA repro)")
          return [ scenario_path, @checkpoint.get("repro_report") ]
        end
      end

      scenario_path, report = run_bug_repro_stage
      @checkpoint.save(
        bug_repro_done: true,
        repro_scenario_path: scenario_path,
        repro_report: report
      )
      [ scenario_path, report ]
    end

    def resolve_qa_stage(repro_scenario_path: nil)
      current_fp = @workspace.state_fingerprint
      if !@fresh &&
         @config.playbook != "babysit-pr" &&
         @checkpoint.get("qa_fingerprint") == current_fp &&
         @checkpoint.get("qa_report")
        @logger.info("RESUME", "Reusing passed QA evidence for current worktree snapshot (#{current_fp[0, 10]}; skipping QA)")
        return @checkpoint.get("qa_report")
      end

      replay_scenario_path = nil
      if !@fresh && @config.playbook == "babysit-pr"
        prev_report = @checkpoint.get("last_passed_qa_report")
        prev_scenario = @checkpoint.get("last_passed_qa_scenario")
        if prev_report.is_a?(Hash) && prev_report["passed"] == true
          if prev_scenario && File.exist?(prev_scenario)
            @logger.info("QA", "Replaying previously passed QA scenario #{File.basename(prev_scenario)} (skipping QA_PLANNER)")
            replay_scenario_path = prev_scenario
          end
        end
      end

      used_scenario_path, report = run_qa_stage(
        repro_scenario_path: repro_scenario_path,
        replay_scenario_path: replay_scenario_path
      )
      @checkpoint.save(
        qa_fingerprint: @workspace.state_fingerprint,
        qa_report: report,
        last_passed_qa_report: report,
        last_passed_qa_scenario: used_scenario_path
      )
      report
    end

    def run_or_resume_worker_and_verify(plan:, feedback:, round:, failure_categories:)
      if round == 1 && !@fresh && @config.playbook != "babysit-pr" && feedback.to_s.strip.empty?
        changed = @workspace.changed_files
        current_fp = @workspace.state_fingerprint

        if !changed.empty? && @checkpoint.get("verified_fingerprint") == current_fp
          @logger.info("RESUME", "Worktree already verified (fingerprint=#{current_fp[0, 10]}); skipping WORKER and VERIFY")
          return 0
        end

        if !changed.empty? && (@checkpoint.get("verified_fingerprint") || @sessions.latest_for(role: "worker"))
          @logger.info("RESUME", "Found existing worktree changes (#{changed.size} file(s)); running VERIFY before invoking WORKER")
          verify_result = @verifier.call(label: "resume-check")
          if verify_result.ok
            @checkpoint.save(verified_fingerprint: @workspace.state_fingerprint, pending_review_feedback: nil)
            @logger.info("RESUME", "Existing worktree passed VERIFY; skipping WORKER")
            return 1
          end

          failure_categories << verify_result.category
          feedback = format_verify_feedback("resume-check", verify_result)
          return 1 + run_worker_and_verify(
            plan: plan,
            feedback: feedback,
            round: round,
            failure_categories: failure_categories
          )
        end
      end

      run_worker_and_verify(
        plan: plan,
        feedback: feedback,
        round: round,
        failure_categories: failure_categories
      )
    end

    def format_verify_feedback(tag, verify_result)
      tail = verify_result.output.lines.last(80).join
      <<~FEEDBACK
          Deterministic verification failed on #{tag} with category `#{verify_result.category}` (exit #{verify_result.exit_code}).
          Fix the root cause without weakening project checks.

          ```
          #{tail}
          ```
        FEEDBACK
    end

    def run_architect_stage
      prompt = @prompts.architect(
        brief: @config.brief,
        done_if: @config.done_if,
        playbook_name: @config.playbook
      )
      File.write(@workspace.artifact_path("architect-prompt.md"), prompt)
      plan_file = @workspace.artifact_path("plan.md")

      stage_name = "ARCHITECT[#{@architect_backend.name}]"
      result = @architect_backend.run(
        stage: stage_name,
        role: "architect",
        worktree_dir: @workspace.worktree_dir,
        prompt: prompt,
        output_file: plan_file,
        sandbox: "read-only",
        model: @architect_spec.model,
        reasoning_effort: @config_file.effort("architect")
      )
      record_stage_result(
        stage: stage_name,
        role: "architect",
        backend: @architect_backend.name,
        model: @architect_spec.model,
        result: result
      )
      result.output
    end

    def run_worker_and_verify(plan:, feedback:, round:, failure_categories:)
      loops = 0
      current_feedback = feedback
      previous_worker = @sessions.latest_for(role: "worker")
      worker_session_id = previous_worker && previous_worker["backend"] == @worker_backend.name ? previous_worker["session_id"] : nil

      @config.max_verify_loops.times do |index|
        attempt = index + 1
        tag = "r#{round}-a#{attempt}"
        has_prior_session = !worker_session_id.nil?
        resuming = has_prior_session && (
          !current_feedback.to_s.strip.empty? ||
          @config.playbook == "babysit-pr" ||
          !@workspace.changed_files.empty?
        )
        prompt = if resuming
          body = !current_feedback.to_s.strip.empty? ? current_feedback.strip : @config.brief.strip
          rebase_note = if @workspace.rebased?
            "\nNote: The harness has already rebased this branch onto the latest `#{@config.base_branch}`. Do not run `git rebase` yourself.\n"
          else
            ""
          end
          <<~RESUME
              Continue working on task `#{@config.task_id}` in this worktree.
              Follow these project rules:
              #{File.read(File.join(Harness::Paths.profile(@repo_root), "rules", "patterns.md"))}
              Address the feedback and run the relevant project checks.
              #{rebase_note}
              #{body}
            RESUME
        else
          @prompts.worker(
            brief: @config.brief,
            done_if: @config.done_if,
            playbook_name: @config.playbook,
            plan: plan,
            feedback: current_feedback
          )
        end
        File.write(@workspace.artifact_path("worker-prompt-#{tag}.md"), prompt)

        stage_name = "WORKER[#{tag}:#{@worker_backend.name}]"
        worker_result = @worker_backend.run(
          stage: stage_name,
          role: "worker",
          worktree_dir: @workspace.worktree_dir,
          prompt: prompt,
          output_file: @workspace.artifact_path("worker-out-#{tag}.md"),
          sandbox: "workspace-write",
          model: @worker_spec.model,
          reasoning_effort: @config_file.effort("worker"),
          resume_session_id: resuming ? worker_session_id : nil
        )
        worker_session_id = worker_result.session_id || worker_session_id
        record_stage_result(
          stage: stage_name,
          role: "worker",
          backend: @worker_backend.name,
          model: @worker_spec.model,
          result: worker_result
        )

        loops += 1
        verify_result = @verifier.call(label: tag)
        if verify_result.ok
          @checkpoint.save(
            verified_fingerprint: @workspace.state_fingerprint,
            pending_review_feedback: nil
          )
          return loops
        end

        failure_categories << verify_result.category
        if attempt == @config.max_verify_loops
          raise VerificationError.new(
            "Verification failed on round #{round} after #{@config.max_verify_loops} attempt(s). " \
            "Last category: #{verify_result.category}",
            category: verify_result.category,
            exit_code: verify_result.exit_code,
            output: verify_result.output
          )
        end

        current_feedback = format_verify_feedback(tag, verify_result)
      end

      loops
    end
  end
end
