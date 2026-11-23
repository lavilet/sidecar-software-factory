require "json"
require "open3"

module Harness
  module Backends
    # Adapter for Google Antigravity CLI (`agy`) supporting Gemini Neon and other models.
    class Antigravity < Base
      DEFAULT_ROLE_CONFIG = {
        "router" => { "sandbox" => "read-only", "reasoning_effort" => "low" },
        "architect" => { "sandbox" => "read-only", "reasoning_effort" => "high" },
        "worker" => { "sandbox" => "workspace-write", "reasoning_effort" => "medium" },
        "reviewer" => { "sandbox" => "read-only", "reasoning_effort" => "medium" },
        "arbiter" => { "sandbox" => "read-only", "reasoning_effort" => "high" },
        "qa" => { "sandbox" => "read-only", "reasoning_effort" => "low" },
        "retro" => { "sandbox" => "read-only", "reasoning_effort" => "medium" }
      }.freeze

      # Explicitly deny shell commands in read-only headless mode so `agy` returns
      # a graceful tool-denial message instead of aborting the turn with empty output
      # ("a tool required the command permission that headless mode cannot prompt for").
      READ_ONLY_SETTINGS = JSON.generate(
        permissions: {
          allow: [
            "read_file(*)",
            "list_dir(*)",
            "find_by_name(*)",
            "grep_search(*)"
          ],
          deny: [
            "command(*)"
          ]
        }
      ).freeze

      def name
        "antigravity"
      end

      def build_command(role:, prompt: "", sandbox: nil, model: nil, reasoning_effort: nil,
        output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        role_cfg = DEFAULT_ROLE_CONFIG.fetch(role.to_s, {})
        effective_sandbox = sandbox || role_cfg.fetch("sandbox", "workspace-write")
        effective_effort = reasoning_effort || role_cfg["reasoning_effort"]

        binary = resolve_binary
        cmd = [ binary, "--output-format", "json" ]

        if effective_sandbox == "read-only"
          cmd.push("--mode", "plan", "--settings", READ_ONLY_SETTINGS)
        else
          cmd.push("--mode", "auto", "--sandbox")
        end

        cmd.push("--conversation", resume_session_id.to_s) if resume_session_id && !resume_session_id.to_s.empty?
        cmd.push("--model", model) if model && !model.empty?
        model_encodes_effort = model.to_s.match?(/-(low|medium|high|xhigh|max)\z/i)
        if effective_effort && !effective_effort.empty? && !model_encodes_effort
          cmd.push("--effort", effective_effort)
        end
        cmd.push("--json-schema", output_schema) if output_schema

        if effective_sandbox == "workspace-write"
          extra_writable_dirs.compact.uniq.each do |dir|
            cmd.push("--add-dir", dir) if Dir.exist?(dir)
          end
        end

        cmd.push("--print", prompt)
        cmd
      end

      MAX_ATTEMPTS = 2
      RETRY_DELAY_SEC = 3

      def run(stage:, role:, worktree_dir:, prompt:, output_file:, sandbox: nil, model: nil,
        reasoning_effort: nil, output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        cmd = build_command(
          role: role,
          prompt: prompt,
          sandbox: sandbox,
          model: model,
          reasoning_effort: reasoning_effort,
          output_schema: output_schema,
          extra_writable_dirs: extra_writable_dirs,
          resume_session_id: resume_session_id
        )

        ensure_binary_available!(cmd.first)
        logged_cmd = cmd[0...-1] + [ "<prompt:#{prompt.bytesize}B>" ]

        attempt = 0
        begin
          attempt += 1
          @logger.info(stage, "Running (antigravity): #{logged_cmd.join(" ")}")

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          stdout = capture_streaming(stage, cmd, chdir: worktree_dir)
          duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

          parsed = parse_json_envelope_full(stdout, stage: stage, expect_structured: !output_schema.nil?)
          raise CommandError, "[#{stage}] Antigravity returned empty output" if parsed[:output].empty?
          if output_schema
            JSON.parse(parsed[:output])
          end
        rescue CommandError, JSON::ParserError => error
          if attempt < MAX_ATTEMPTS
            @logger.info(stage, "Transient Antigravity failure on attempt #{attempt}/#{MAX_ATTEMPTS} (#{error.message}); retrying in #{RETRY_DELAY_SEC}s...")
            sleep(RETRY_DELAY_SEC)
            retry
          end
          raise CommandError, "[#{stage}] Antigravity failed after #{attempt} attempt(s): #{error.message}"
        end

        if parsed[:session_id]
          u = parsed[:usage] || {}
          @logger.info(
            stage,
            "conversation_id=#{parsed[:session_id]} in=#{u["input_tokens"]} cached=#{u["cached_input_tokens"]} " \
            "out=#{u["output_tokens"]} thinking=#{u["reasoning_tokens"]}"
          )
        end

        File.write(output_file, "#{parsed[:output]}\n")
        Result.new(
          output: parsed[:output],
          duration_sec: duration,
          command: logged_cmd,
          session_id: parsed[:session_id] || resume_session_id,
          usage: parsed[:usage]
        )
      end

      def parse_json_envelope(raw, stage:, expect_structured: false)
        parse_json_envelope_full(raw, stage: stage, expect_structured: expect_structured)[:output]
      end

      def parse_json_envelope_full(raw, stage:, expect_structured: false)
        envelope = JSON.parse(raw.strip)
        if envelope["status"] && envelope["status"] != "SUCCESS"
          raise CommandError, "[#{stage}] Antigravity returned status=#{envelope["status"]}"
        end

        output = if expect_structured && envelope.key?("structured_output") && !envelope["structured_output"].nil?
          JSON.generate(envelope["structured_output"])
        else
          envelope["response"].to_s.strip
        end

        raw_usage = envelope["usage"]
        usage = if raw_usage.is_a?(Hash)
          inp = raw_usage.fetch("input_tokens", 0).to_i
          out = raw_usage.fetch("output_tokens", 0).to_i
          {
            "input_tokens" => inp,
            "cached_input_tokens" => raw_usage.fetch("cache_read_tokens", 0).to_i,
            "output_tokens" => out,
            "reasoning_tokens" => raw_usage.fetch("thinking_tokens", 0).to_i,
            "total_tokens" => raw_usage.fetch("total_tokens", inp + out).to_i
          }
        end

        { output: output, session_id: envelope["conversation_id"], usage: usage }
      rescue JSON::ParserError => error
        raise CommandError, "[#{stage}] Failed to parse Antigravity JSON output: #{error.message}"
      end

      private
      def resolve_binary
        return ENV["HARNESS_AGY_BIN"] if ENV["HARNESS_AGY_BIN"] && !ENV["HARNESS_AGY_BIN"].empty?

        local_agy = File.expand_path("~/.local/bin/agy")
        return local_agy if File.executable?(local_agy)

        "agy"
      end

      def ensure_binary_available!(binary)
        return if File.executable?(binary)

        _, status = Open3.capture2e("which", binary)
        return if status.success?

        raise CommandError,
          "Antigravity CLI '#{binary}' not found on PATH. Install `agy`, set HARNESS_AGY_BIN, " \
          "or choose another backend (e.g. --reviewers codex,gemini)."
      end

      def capture_streaming(stage, cmd, chdir:)
        stdout_chunks = []
        exit_status = nil
        env = {}

        Open3.popen3(env, *cmd, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
          stdin.close

          err_reader = Thread.new do
            stderr.each_line { |line| @logger.info(stage, line.chomp) }
          end

          stdout.each_line do |line|
            stdout_chunks << line
          end

          err_reader.join
          exit_status = wait_thr.value
        end

        unless exit_status&.success?
          raise CommandError, "[#{stage}] Antigravity exited with status #{exit_status&.exitstatus}"
        end

        stdout_chunks.join
      end
    end
  end
end
