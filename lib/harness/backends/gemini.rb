require "json"
require "open3"

module Harness
  module Backends
    # Adapter for Google Gemini CLI (`gemini`) supporting Gemini Neon / Pro / Flash models.
    class Gemini < Base
      DEFAULT_ROLE_CONFIG = {
        "architect" => { "sandbox" => "read-only" },
        "worker" => { "sandbox" => "workspace-write" },
        "reviewer" => { "sandbox" => "read-only" }
      }.freeze

      def name
        "gemini"
      end

      def build_command(role:, sandbox: nil, model: nil, extra_writable_dirs: [])
        role_cfg = DEFAULT_ROLE_CONFIG.fetch(role.to_s, {})
        effective_sandbox = sandbox || role_cfg.fetch("sandbox", "workspace-write")

        binary = resolve_binary
        cmd = [ binary, "-o", "text" ]

        if effective_sandbox == "read-only"
          cmd.push("--approval-mode", "default")
        else
          cmd.push("--sandbox", "--approval-mode", "auto_edit")
        end

        cmd.push("-m", model) if model && !model.empty?

        if effective_sandbox == "workspace-write"
          extra_writable_dirs.compact.uniq.each do |dir|
            cmd.push("--include-directories", dir) if Dir.exist?(dir)
          end
        end

        cmd
      end

      def run(stage:, role:, worktree_dir:, prompt:, output_file:, sandbox: nil, model: nil,
        reasoning_effort: nil, output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        cmd = build_command(
          role: role,
          sandbox: sandbox,
          model: model,
          extra_writable_dirs: extra_writable_dirs
        )

        ensure_binary_available!(cmd.first)
        effective_prompt = append_schema_instruction(prompt, output_schema)
        env = runtime_env(cmd.first)

        @logger.info(stage, "Running (gemini): #{cmd.join(" ")}")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout = capture_streaming(stage, env, cmd, effective_prompt, chdir: worktree_dir)
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

        cleaned = output_schema ? extract_json_object(stdout, stage) : stdout.strip
        raise CommandError, "[#{stage}] Gemini returned empty output" if cleaned.empty?

        File.write(output_file, "#{cleaned}\n")
        Result.new(output: cleaned, duration_sec: duration, command: cmd)
      end

      def extract_json_object(raw, stage)
        stripped = raw.strip
        fenced = stripped.match(/```(?:json)?\s*(\{.*\})\s*```/m)
        candidate = fenced ? fenced[1] : stripped

        unless candidate.start_with?("{") && candidate.end_with?("}")
          first_brace = candidate.index("{")
          last_brace = candidate.rindex("}")
          if first_brace && last_brace && last_brace > first_brace
            candidate = candidate[first_brace..last_brace]
          end
        end

        JSON.parse(candidate)
        candidate
      rescue JSON::ParserError => error
        raise CommandError, "[#{stage}] Gemini did not return valid JSON matching schema: #{error.message}"
      end

      private
      def resolve_binary
        return ENV["HARNESS_GEMINI_BIN"] if ENV["HARNESS_GEMINI_BIN"] && !ENV["HARNESS_GEMINI_BIN"].empty?

        out, status = Open3.capture2e("which", "gemini")
        return out.strip if status.success? && !out.strip.empty?

        "gemini"
      end

      def ensure_binary_available!(binary)
        return if File.executable?(binary)

        _, status = Open3.capture2e("which", binary)
        return if status.success?

        raise CommandError,
          "Gemini CLI '#{binary}' not found. Install `@google/gemini-cli` or set HARNESS_GEMINI_BIN."
      end

      # Prepend the binary's bin directory to PATH so nvm-installed gemini uses its matching Node runtime.
      def runtime_env(binary)
        env = {}
        if binary.include?("/")
          bin_dir = File.dirname(binary)
          env["PATH"] = "#{bin_dir}:#{ENV.fetch("PATH", "")}"
        end
        env
      end

      def append_schema_instruction(prompt, output_schema)
        return prompt unless output_schema && File.exist?(output_schema)

        schema = File.read(output_schema).strip
        <<~PROMPT
            #{prompt}

            ---

            ## Strict Output Format
            Return ONLY a single valid JSON object conforming strictly to this JSON Schema.
            Do NOT wrap it in prose or commentary outside the JSON object.

            ```json
            #{schema}
            ```
          PROMPT
      end

      def capture_streaming(stage, env, cmd, stdin_data, chdir:)
        stdout_chunks = []
        exit_status = nil

        Open3.popen3(env, *cmd, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
          writer = Thread.new do
            stdin.write(stdin_data)
            stdin.close
          rescue Errno::EPIPE
            @logger.info(stage, "stdin closed early by gemini process")
          end

          err_reader = Thread.new do
            stderr.each_line { |line| @logger.info(stage, line.chomp) }
          end

          stdout.each_line do |line|
            stdout_chunks << line
          end

          writer.join
          err_reader.join
          exit_status = wait_thr.value
        end

        unless exit_status&.success?
          raise CommandError, "[#{stage}] Gemini exited with status #{exit_status&.exitstatus}"
        end

        stdout_chunks.join
      end
    end
  end
end
