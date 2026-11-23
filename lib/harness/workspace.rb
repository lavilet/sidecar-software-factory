require "digest"
require "fileutils"
require "open3"

module Harness
  class Workspace
    attr_reader :repo_root, :task_id, :base_branch, :branch, :worktree_dir, :artifacts_dir

    def initialize(repo_root:, task_id:, base_branch:)
      @repo_root = File.expand_path(repo_root)
      @task_id = Harness::Paths.task!(task_id)
      @base_branch = base_branch
      @branch = "harness/#{task_id}"
      @worktree_dir = File.join(Harness::Paths.profile(@repo_root), "worktrees", task_id)
      @artifacts_dir = File.join(Harness::Paths.profile(@repo_root), "runs", task_id)
      @rebased = false
    end

    def rebased?
      @rebased
    end

    def prepare!
      FileUtils.mkdir_p(File.dirname(@worktree_dir))
      FileUtils.mkdir_p(@artifacts_dir)

      unless Dir.exist?(@worktree_dir)
        if branch_exists?(@branch)
          run_git("worktree", "add", @worktree_dir, @branch)
        else
          start_ref = resolve_fresh_base_ref
          run_git("worktree", "add", "-b", @branch, @worktree_dir, start_ref)
        end
      end

      self
    end

    def artifact_path(name)
      File.join(@artifacts_dir, name)
    end

    def telemetry_path
      File.join(Harness::Paths.profile(@repo_root), "runs", "telemetry.jsonl")
    end

    def changed_files
      stage_intent_for_new_files
      out, = capture_git("diff", "--name-only", diff_base_ref, chdir: @worktree_dir)
      out.lines.map(&:strip).reject(&:empty?)
    end

    def files_changed_since(sha)
      return changed_files if sha.to_s.strip.empty?

      _, valid_st = Open3.capture2e("git", "cat-file", "-e", "#{sha}^{commit}", chdir: @worktree_dir)
      return changed_files unless valid_st.success?

      stage_intent_for_new_files
      out, st = Open3.capture2e("git", "diff", "--name-only", sha, chdir: @worktree_dir)
      st.success? ? out.lines.map(&:strip).reject(&:empty?) : changed_files
    end

    def full_diff(max_bytes: 90_000)
      stage_intent_for_new_files
      out, = capture_git("diff", diff_base_ref, chdir: @worktree_dir)
      return out if out.bytesize <= max_bytes

      "#{out.byteslice(0, max_bytes)}\n\n... [DIFF TRUNCATED: inspect remaining files in worktree]"
    end

    def protected_files_touched
      list = File.join(Harness::Paths.profile(@repo_root), "protected-paths.txt")
      patterns = File.readlines(list, chomp: true).map(&:strip).reject { |s| s.empty? || s.start_with?("#") }
      changed_files.select { |path| patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) } }
    end

    def head_sha
      out, = capture_git("rev-parse", "HEAD", chdir: @worktree_dir)
      out.strip
    end

    # Deterministic SHA256 fingerprint of the current worktree state (HEAD + all tracked & untracked diffs).
    def state_fingerprint
      stage_intent_for_new_files
      head = head_sha
      diff, = capture_git("diff", "--binary", diff_base_ref, chdir: @worktree_dir)
      Digest::SHA256.hexdigest("#{head}\n#{diff}")
    end

    # Fetches the latest base branch from origin (when present) and rebases the worktree
    # onto it if the base has advanced since the worktree was created. Preserves uncommitted
    # work safely via git stash and restores the original state on conflict.
    def sync_with_base!(logger: nil)
      target_ref = fetch_and_resolve_base_ref
      _, ancestor_st = Open3.capture2e("git", "merge-base", "--is-ancestor", target_ref, "HEAD", chdir: @worktree_dir)
      if ancestor_st.success?
        return { status: :up_to_date, base_ref: target_ref }
      end

      orig_head = head_sha
      status_out, = capture_git("status", "--porcelain", chdir: @worktree_dir)
      stashed = false

      unless status_out.strip.empty?
        # Clear any `git add -N` intent-to-add entries before stashing so git stash push succeeds cleanly.
        Open3.capture2e("git", "reset", "--quiet", chdir: @worktree_dir)
        run_git("stash", "push", "--include-untracked", "-m", "harness-auto-rebase", chdir: @worktree_dir)
        stashed = true
      end

      rebase_out, rebase_st = Open3.capture2e("git", "rebase", target_ref, chdir: @worktree_dir)
      unless rebase_st.success?
        Open3.capture2e("git", "rebase", "--abort", chdir: @worktree_dir)
        restore_stash!(orig_head) if stashed
        logger&.info("SYNC", "Auto-rebase onto #{target_ref} hit conflicts; restored original worktree state")
        return { status: :conflict, base_ref: target_ref, error: rebase_out }
      end

      if stashed
        pop_out, pop_st = Open3.capture2e("git", "stash", "pop", chdir: @worktree_dir)
        unless pop_st.success?
          restore_stash!(orig_head)
          logger&.info("SYNC", "Stash pop after rebase onto #{target_ref} hit conflicts; restored original worktree state")
          return { status: :conflict, base_ref: target_ref, error: pop_out }
        end
      end

      @rebased = true
      logger&.info("SYNC", "Rebased #{@branch} cleanly onto #{target_ref}")
      { status: :rebased, base_ref: target_ref }
    end

    def commit_and_push!(message)
      run_git("add", "-A", chdir: @worktree_dir)
      status, = capture_git("status", "--porcelain", chdir: @worktree_dir)
      if status.strip.empty?
        ahead, = capture_git("rev-list", "--count", "#{diff_base_ref}..HEAD", chdir: @worktree_dir)
        raise CommandError, "No changes to commit in #{@worktree_dir}" if ahead.strip.to_i == 0
      else
        run_git("commit", "-m", message, chdir: @worktree_dir)
      end

      push_args = [ "push", "-u", "origin", @branch ]
      push_args.insert(1, "--force-with-lease") if @rebased || diverged_from_remote_branch?
      run_git(*push_args, chdir: @worktree_dir)
      head_sha
    end

    private
    def diverged_from_remote_branch?
      remote_ref = "refs/remotes/origin/#{@branch}"
      _, exists_st = Open3.capture2e("git", "show-ref", "--verify", "--quiet", remote_ref, chdir: @worktree_dir)
      return false unless exists_st.success?

      _, anc_st = Open3.capture2e("git", "merge-base", "--is-ancestor", remote_ref, "HEAD", chdir: @worktree_dir)
      !anc_st.success?
    end

    def diff_base_ref
      remote_ref = "refs/remotes/origin/#{@base_branch}"
      _, ref_st = Open3.capture2e("git", "show-ref", "--verify", "--quiet", remote_ref, chdir: @repo_root)
      ref_st.success? ? "origin/#{@base_branch}" : @base_branch
    end

    def fetch_and_resolve_base_ref
      return @base_branch if @base_branch.match?(/\A[0-9a-f]{40,64}\z/)
      _, remote_st = Open3.capture2e("git", "remote", "get-url", "origin", chdir: @repo_root)
      if remote_st.success?
        _, fetch_st = Open3.capture2e("git", "fetch", "origin", @base_branch, chdir: @repo_root)
        if fetch_st.success?
          _, ref_st = Open3.capture2e("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{@base_branch}", chdir: @repo_root)
          return "origin/#{@base_branch}" if ref_st.success?
        end
      end
      @base_branch
    end

    def restore_stash!(orig_head)
      Open3.capture2e("git", "reset", "--hard", orig_head, chdir: @worktree_dir)
      Open3.capture2e("git", "stash", "pop", chdir: @worktree_dir)
    end

    def resolve_fresh_base_ref
      fetch_and_resolve_base_ref
    end

    def branch_exists?(name)
      _, status = Open3.capture2e("git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}", chdir: @repo_root)
      status.success?
    end

    def stage_intent_for_new_files
      untracked, = capture_git("ls-files", "-z", "--others", "--exclude-standard", chdir: @worktree_dir)
      files = untracked.split("\0")
      return if files.empty?

      run_git("add", "-N", "--", *files, chdir: @worktree_dir)
    end

    def run_git(*args, chdir: @repo_root)
      out, status = Open3.capture2e("git", *args, chdir: chdir)
      raise CommandError, "git #{args.join(" ")} failed:\n#{out}" unless status.success?

      out
    end

    def capture_git(*args, chdir: @repo_root)
      out, status = Open3.capture2e("git", *args, chdir: chdir)
      raise CommandError, "git #{args.join(" ")} failed:\n#{out}" unless status.success?

      [ out, status ]
    end
  end
end
