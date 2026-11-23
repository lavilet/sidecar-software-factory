require "shellwords"
require "fileutils"
require "json"
require "time"

module Harness
  # Records backend session IDs (Codex thread_id, Antigravity conversation_id) and token usage
  # per task so Worker runs can resume sessions and humans can attach interactively.
  class SessionStore
    def initialize(artifacts_dir:)
      @path = File.join(File.expand_path(artifacts_dir), "sessions.json")
      FileUtils.mkdir_p(File.dirname(@path))
    end

    def entries
      return [] unless File.exist?(@path)

      JSON.parse(File.read(@path))
    end

    def record(stage:, role:, backend:, model:, session_id:, worktree_dir:, duration_sec:, usage:, estimated_cost_usd:)
      list = entries
      list << {
        "stage" => stage,
        "role" => role.to_s,
        "backend" => backend.to_s,
        "model" => model,
        "session_id" => session_id,
        "worktree_dir" => worktree_dir,
        "duration_sec" => duration_sec,
        "usage" => usage,
        "estimated_cost_usd" => estimated_cost_usd,
        "takeover_cmd" => self.class.takeover_command(backend: backend, session_id: session_id, worktree_dir: worktree_dir),
        "recorded_at" => Time.now.utc.iso8601
      }
      File.write(@path, JSON.pretty_generate(list))
      list.last
    end

    def latest_for(role:)
      entries.reverse.find { |entry| entry["role"] == role.to_s && entry["session_id"] && !entry["session_id"].empty? }
    end

    def self.takeover_command(backend:, session_id:, worktree_dir:)
      return nil unless session_id && !session_id.to_s.empty?

      argv = takeover_argv(backend, session_id)
      "cd #{Shellwords.escape(worktree_dir)} && #{Shellwords.join(argv)}" if argv
    end

    def self.takeover_argv(backend, session_id)
      case backend.to_s
      when "codex" then ["codex", "resume", session_id]
      when "antigravity" then [ENV.fetch("HARNESS_AGY_BIN", "agy"), "--conversation", session_id]
      when "gemini" then [ENV.fetch("HARNESS_GEMINI_BIN", "gemini"), "--resume", session_id]
      end
    end
  end
end
