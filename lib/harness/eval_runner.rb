require "securerandom"
require "fileutils"
require "json"
require "open3"

module Harness
  # Runs frozen regression evals against historical base SHAs with hidden held-out specs
  # that the agent never sees inside its worktree.
  class EvalRunner
    def initialize(repo_root:, logger:, runner_factory:)
      @repo_root = File.expand_path(repo_root)
      @logger = logger
      @runner_factory = runner_factory
      @evals_dir = File.join(Harness::Paths.profile(@repo_root), "evals")
    end

    def call(task_filter: nil, update_baseline: false)
      task_files = Dir.glob(File.join(@evals_dir, "tasks", "*.json")).sort
      if task_filter && !task_filter.empty?
        task_files = task_files.select { |path| File.basename(path).include?(task_filter) }
      end

      if task_files.empty?
        @logger.info("EVAL", "No eval task JSON files found under #{@evals_dir}/tasks/")
        return { total: 0, passed: 0, results: [], pass_rate: 0.0 }
      end

      results = task_files.map { |path| run_single_task(JSON.parse(File.read(path))) }
      passed = results.count { |r| r[:agent_ok] && r[:held_out_passed] }
      summary = {
        ran_at: Time.now.utc.iso8601,
        total: results.size,
        passed: passed,
        pass_rate: (passed.to_f / results.size).round(3),
        results: results
      }

      baseline_path = File.join(@evals_dir, "baseline.json")
      if update_baseline
        File.write(baseline_path, JSON.pretty_generate(summary))
        @logger.info("EVAL", "Updated baseline at #{baseline_path}")
      elsif File.exist?(baseline_path)
        baseline = JSON.parse(File.read(baseline_path))
        @logger.info("EVAL", "Pass rate: #{summary[:pass_rate]} (baseline: #{baseline["pass_rate"]})")
      end

      summary
    end

    private
    def run_single_task(task)
      id = Harness::Paths.task!(task.fetch("id"))
      eval_id = "eval-#{id[0,50]}-#{SecureRandom.hex(6)}"
      worktree_dir = File.join(Harness::Paths.profile(@repo_root), "worktrees", eval_id)
      branch = "harness/#{eval_id}"
      check = File.join(@evals_dir, "checks", Harness::Paths.task!(task.fetch("check")))
      raise Error, "Missing executable held-out check: #{check}" unless File.executable?(check)
      sha = task.fetch("base_sha")
      raise Error, "Use a full Git commit SHA for base_sha" unless /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/.match?(sha)

      FileUtils.mkdir_p(File.dirname(worktree_dir))
      run_git("worktree", "add", "-b", branch, worktree_dir, sha)
      created = true
      @logger.info("EVAL", "Running frozen eval '#{task["id"]}' on #{task["base_sha"]}")
      agent_ok = begin
        @runner_factory.call(
          task_id: eval_id,
          playbook: task["playbook"],
          brief: task["brief"],
          done_if: task["done_if"],
          base_branch: task["base_sha"]
        )
        true
      rescue Error => error
        @logger.info("EVAL", "Agent failed on '#{task["id"]}': #{error.message}")
        false
      end

      output, status = Open3.capture2e([check, check], chdir: worktree_dir)
      @logger.info("EVAL", output) unless status.success?
      { id: id, agent_ok: agent_ok, held_out_passed: status.success? }
    ensure
      if created
        run_git("worktree", "remove", "--force", worktree_dir)
        run_git("branch", "-D", branch)
      end
    end

    def run_git(*args)
      out, status = Open3.capture2e("git", *args, chdir: @repo_root)
      raise CommandError, "git #{args.join(" ")} failed:\n#{out}" unless status.success?

      out
    end
  end
end
