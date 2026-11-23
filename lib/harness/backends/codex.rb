require "json"
require "open3"

module Harness
  module Backends
    class Codex < Base
      DEFAULT_ROLE_CONFIG = {
        "router" => { "sandbox" => "read-only", "reasoning_effort" => "low" },
        "architect" => { "sandbox" => "read-only", "reasoning_effort" => "high" },
        "worker" => { "sandbox" => "workspace-write", "reasoning_effort" => "medium" },
        "reviewer" => { "sandbox" => "read-only", "reasoning_effort" => "medium" },
        "arbiter" => { "sandbox" => "read-only", "reasoning_effort" => "high" },
        "qa" => { "sandbox" => "read-only", "reasoning_effort" => "low" },
        "retro" => { "sandbox" => "read-only", "reasoning_effort" => "medium" }
      }.freeze

      ROLE_IDLE_TIMEOUTS = {
        "router" => 150,
        "qa" => 180,
        "reviewer" => 300,
        "arbiter" => 300,
        "retro" => 300,
        "architect" => 360,
        "worker" => 600
      }.freeze

      def name
        "codex"
      end

      def build_command(role:, worktree_dir:, output_file:, sandbox: nil, model: nil,
        reasoning_effort: nil, output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        role_cfg = role_defaults(role)
        effective_sandbox = sandbox || role_cfg.fetch("sandbox", "workspace-write")
        effective_effort = reasoning_effort || role_cfg["reasoning_effort"]

        if resume_session_id && !resume_session_id.to_s.empty?
          cmd = [
            "codex", "exec", "resume",
            "-c", "sandbox_mode=\"#{effective_sandbox}\"",
            "-c", "approval_policy=\"never\"",
            "--json",
            "-o", output_file
          ]
          cmd.push("-c", "model_reasoning_effort=\"#{effective_effort}\"") if effective_effort && !effective_effort.empty?
          cmd.push("-m", model) if model && !model.empty?
          cmd.push("--output-schema", output_schema) if output_schema
          cmd.push(resume_session_id.to_s, "-")
          return cmd
        end

        cmd = [
          "codex", "exec",
          "-C", worktree_dir,
          "-s", effective_sandbox,
          "-c", "approval_policy=\"never\"",
          "--json",
          "-o", output_file
        ]

        if effective_effort && !effective_effort.empty?
          cmd.push("-c", "model_reasoning_effort=\"#{effective_effort}\"")
        end

        if model && !model.empty?
          cmd.push("-m", model)
        end

        if effective_sandbox == "workspace-write"
          extra_writable_dirs.compact.uniq.each do |dir|
            cmd.push("--add-dir", dir) if Dir.exist?(dir)
          end
        end

        cmd.push("--output-schema", output_schema) if output_schema
        cmd.push("-")
        cmd
      end

      def run(stage:, role:, worktree_dir:, prompt:, output_file:, sandbox: nil, model: nil,
        reasoning_effort: nil, output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        cmd = build_command(
          role: role,
          worktree_dir: worktree_dir,
          output_file: output_file,
          sandbox: sandbox,
          model: model,
          reasoning_effort: reasoning_effort,
          output_schema: output_schema,
          extra_writable_dirs: extra_writable_dirs,
          resume_session_id: resume_session_id
        )

        @logger.info(stage, "Running: #{cmd.join(" ")}")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        idle_timeout = (ENV["HARNESS_IDLE_TIMEOUT"] || ROLE_IDLE_TIMEOUTS.fetch(role.to_s, 300)).to_i
        meta = stream_command(stage, {}, cmd, prompt, chdir: worktree_dir, idle_timeout: idle_timeout)
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

        unless File.exist?(output_file) && !File.read(output_file).strip.empty?
          raise CommandError, "[#{stage}] Codex did not write output file: #{output_file}"
        end

        Result.new(
          output: File.read(output_file),
          duration_sec: duration,
          command: cmd,
          session_id: meta[:session_id] || resume_session_id,
          usage: meta[:usage]
        )
      end

      private
      def role_defaults(role)
        key = role.to_s
        DEFAULT_ROLE_CONFIG.fetch(key, {})
      end

      def stream_command(stage, env, cmd, stdin_data, chdir:, idle_timeout: 300)
        exit_status = nil
        session_id = nil
        last_error = nil
        timed_out = false
        usage = {
          "input_tokens" => 0,
          "cached_input_tokens" => 0,
          "output_tokens" => 0,
          "reasoning_tokens" => 0,
          "total_tokens" => 0
        }

        Open3.popen2e(env, *cmd, chdir: chdir, pgroup: true) do |stdin, stdout_err, wait_thr|
          last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          activity_mutex = Mutex.new
          done = false

          watchdog = Thread.new do
            loop do
              sleep(2)
              elapsed = activity_mutex.synchronize do
                break nil if done

                Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_activity
              end
              break if elapsed.nil?
              next if elapsed < idle_timeout

              timed_out = true
              @logger.info(stage, "[ERROR] Idle watchdog triggered after #{elapsed.round}s without output; terminating process group #{wait_thr.pid}")
              terminate_pgroup(wait_thr.pid)
              break
            end
          end

          writer = Thread.new do
            stdin.write(stdin_data)
            stdin.close
          rescue Errno::EPIPE
            @logger.info(stage, "stdin closed early by child process")
          end

          stdout_err.each_line do |raw_line|
            activity_mutex.synchronize { last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            line = raw_line.chomp
            next if line.empty?

            event = parse_json_line(line)
            if event
              session_id ||= event["thread_id"] if event["type"] == "thread.started"
              accumulate_usage(usage, event["usage"]) if event["type"] == "turn.completed" && event["usage"]
              if event["type"] == "error" && event["message"]
                last_error = event["message"]
              elsif event["type"] == "turn.failed"
                last_error = event.dig("error", "message") || event["error"].to_s
              end
              log_codex_event(stage, event)
            else
              @logger.info(stage, line)
            end
          end

          activity_mutex.synchronize { done = true }
          watchdog.join(3)
          writer.join
          exit_status = wait_thr.value
        end

        if timed_out
          raise CommandError, "[#{stage}] Codex timed out after #{idle_timeout}s without output"
        end

        unless exit_status&.success?
          detail = last_error ? " - #{last_error}" : ""
          raise CommandError, "[#{stage}] Codex exited with status #{exit_status&.exitstatus}#{detail}"
        end

        usage["total_tokens"] = usage["input_tokens"] + usage["output_tokens"]
        { session_id: session_id, usage: usage }
      end

      def terminate_pgroup(pid)
        Process.kill("TERM", -pid)
        sleep(2)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def parse_json_line(line)
        return nil unless line.start_with?("{")

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def accumulate_usage(totals, turn_usage)
        totals["input_tokens"] += turn_usage.fetch("input_tokens", 0).to_i
        totals["cached_input_tokens"] += turn_usage.fetch("cached_input_tokens", 0).to_i
        totals["output_tokens"] += turn_usage.fetch("output_tokens", 0).to_i
        totals["reasoning_tokens"] += turn_usage.fetch("reasoning_output_tokens", 0).to_i
      end

      def log_codex_event(stage, event)
        case event["type"]
        when "thread.started"
          @logger.info(stage, "[SESSION] id=#{event["thread_id"]}")
        when "error"
          @logger.info(stage, "[ERROR] #{event["message"]}")
        when "turn.failed"
          @logger.info(stage, "[ERROR] TURN_FAILED: #{event.dig("error", "message") || event["error"]}")
        when "turn.completed"
          u = event["usage"] || {}
          @logger.info(
            stage,
            "[USAGE] in=#{u["input_tokens"]} cached=#{u["cached_input_tokens"]} " \
            "out=#{u["output_tokens"]} reasoning=#{u["reasoning_output_tokens"]}"
          )
        when "item.completed"
          item = event["item"] || {}
          case item["type"]
          when "command_execution"
            exit_code = item["exit_code"]
            @logger.info(stage, "[TOOL:CMD exit=#{exit_code}] #{item["command"].to_s.strip}")
            output = item["aggregated_output"].to_s.strip
            if exit_code.to_i != 0 && !output.empty?
              @logger.info(stage, "[TOOL:OUTPUT]\n#{output}")
            end
          when "file_change"
            changes = Array(item["changes"]).map do |change|
              change.is_a?(Hash) ? "#{change["kind"] || "edit"}:#{change["path"]}" : change.to_s
            end
            summary = changes.empty? ? "1 change" : changes.join(", ")
            @logger.info(stage, "[TOOL:EDIT] #{summary}")
          when "mcp_tool_call"
            @logger.info(stage, "[TOOL:MCP] #{item["server"]}/#{item["tool"]} #{item["arguments"]}")
          when "web_search"
            @logger.info(stage, "[TOOL:SEARCH] #{item["query"]}")
          when "reasoning"
            text = item["text"].to_s.strip
            @logger.info(stage, "[THINKING] #{text}") unless text.empty?
          when "agent_message"
            text = item["text"].to_s.strip
            @logger.info(stage, "[AGENT] #{text}") unless text.empty?
          end
        end
      end
    end
  end
end
