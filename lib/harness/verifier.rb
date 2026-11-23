require "open3"

module Harness
  class Verifier
    Result = Data.define(:ok, :category, :exit_code, :output, :duration_sec)

    def initialize(repo_root:, workspace:, logger:)
      @repo_root = repo_root
      @workspace = workspace
      @logger = logger
    end

    def call(label:)
      cmd = [File.join(Harness::Paths.profile(@repo_root), "hooks", "verify")]
      @logger.info("VERIFY", "Running (#{label}): #{cmd.join(" ")}")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, status = Open3.capture2e([cmd.first, cmd.first], chdir: @workspace.worktree_dir)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

      File.write(@workspace.artifact_path("verify-#{label}.log"), output)

      if status.success?
        @logger.info("VERIFY", "PASSED (#{label}) in #{duration}s")
        return Result.new(ok: true, category: nil, exit_code: 0, output: output, duration_sec: duration)
      end

      category = detect_category(output)
      @logger.info("VERIFY", "FAILED (#{label}) category=#{category} exit=#{status.exitstatus} in #{duration}s")
      Result.new(ok: false, category: category, exit_code: status.exitstatus, output: output, duration_sec: duration)
    end

    private
    def detect_category(output)
      match = output.match(/\[FAIL_CATEGORY=([a-z0-9_-]+)\]/)
      return match[1] if match

      "verification"
    end
  end
end
