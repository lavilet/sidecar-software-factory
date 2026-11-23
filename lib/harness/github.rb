require "json"
require "open3"

module Harness
  class GitHub
    def initialize(repo_root: Dir.pwd)
      @repo_root = File.expand_path(repo_root)
    end

    def issues_with_label(label)
      out = run_gh(
        "issue", "list",
        "--label", label,
        "--state", "open",
        "--json", "number,title,body,comments,labels"
      )
      JSON.parse(out)
    end

    def issue_view(number)
      out = run_gh(
        "issue", "view", number.to_s,
        "--json", "number,title,body,state,labels"
      )
      JSON.parse(out)
    end

    def comment_issue(number, body)
      run_gh("issue", "comment", number.to_s, "--body", body)
    end

    def transition_label(number, remove: nil, add: nil)
      args = [ "issue", "edit", number.to_s ]
      args.push("--remove-label", remove) if remove && !remove.empty?
      args.push("--add-label", add) if add && !add.empty?
      return if args.size == 3

      run_gh(*args)
    end

    def pr_view(pr_ref)
      out = run_gh(
        "pr", "view", pr_ref.to_s,
        "--json", "number,url,state,headRefName,baseRefName,headRefOid,mergeCommit,reviews,comments"
      )
      pr = JSON.parse(out)
      # Use REST reviews so numeric `id` matches `pull_request_review_id` on inline comments.
      pr["reviews"] = pr_reviews(pr["number"]) if pr["number"]
      pr
    end

    def pr_reviews(pr_number)
      out = run_gh("api", "repos/{owner}/{repo}/pulls/#{pr_number}/reviews", "--paginate")
      return [] if out.strip.empty?

      JSON.parse(out)
    end

    def pr_review_comments(pr_number)
      out = run_gh("api", "repos/{owner}/{repo}/pulls/#{pr_number}/comments", "--paginate")
      return [] if out.strip.empty?

      JSON.parse(out)
    end

    def comment_pr(pr_number, body)
      run_gh("pr", "comment", pr_number.to_s, "--body", body)
    end

    def human_diff(agent_sha, merge_sha)
      return { lines: 0, diff: "" } if agent_sha.nil? || merge_sha.nil? || agent_sha == merge_sha

      Open3.capture2e("git", "fetch", "origin", chdir: @repo_root)
      numstat, st1 = Open3.capture2e("git", "diff", "--numstat", "#{agent_sha}..#{merge_sha}", chdir: @repo_root)
      return { lines: 0, diff: "" } unless st1.success?

      changed_lines = numstat.lines.sum do |line|
        added, deleted, = line.split("\t")
        added.to_i + deleted.to_i
      end

      diff, st2 = Open3.capture2e("git", "diff", "#{agent_sha}..#{merge_sha}", chdir: @repo_root)
      { lines: changed_lines, diff: st2.success? ? diff : "" }
    end

    private
    def run_gh(*args)
      out, status = Open3.capture2e("gh", *args, chdir: @repo_root)
      raise CommandError, "gh #{args.join(" ")} failed:\n#{out}" unless status.success?

      out
    end
  end
end
