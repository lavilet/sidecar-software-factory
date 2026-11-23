require "digest"
require "open3"

module Harness
  module Paths
    ROOT = File.realpath("../..", __dir__)
    module_function

    def profile(repo_root)
      target = File.realpath(repo_root)
      key = Digest::SHA256.hexdigest(target)[0, 16]
      state = File.expand_path(ENV.fetch("FACTORY_STATE_DIR", File.join(ROOT, "projects")))
      abort "Factory state must live outside the target" if state == target || state.start_with?(target + "/")
      File.join(state, "#{File.basename(target)}-#{key}")
    end

    def task!(id)
      abort "Use a task ID of 1 to 80 letters, digits, hyphens or underscores" unless /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/.match?(id)
      id
    end

    def base_branch(repo_root)
      remote, status = Open3.capture2("git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", chdir: repo_root)
      return remote.strip.delete_prefix("origin/") if status.success?
      local, status = Open3.capture2("git", "symbolic-ref", "--quiet", "--short", "HEAD", chdir: repo_root)
      abort "Cannot infer a base branch from detached HEAD" unless status.success?
      local.strip
    end
  end
end
