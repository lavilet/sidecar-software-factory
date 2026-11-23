module Harness
  module Backends
    Result = Data.define(:output, :duration_sec, :command, :session_id, :usage) do
      def initialize(output:, duration_sec:, command:, session_id: nil, usage: nil)
        super(
          output: output,
          duration_sec: duration_sec,
          command: command,
          session_id: session_id,
          usage: usage
        )
      end
    end

    Spec = Data.define(:backend, :model)

    class Base
      def initialize(logger:, repo_root:)
        @logger = logger
        @repo_root = repo_root
      end

      def name
        raise NotImplementedError, "#{self.class} must implement #name"
      end

      def run(stage:, role:, worktree_dir:, prompt:, output_file:, sandbox: nil, model: nil,
        reasoning_effort: nil, output_schema: nil, extra_writable_dirs: [], resume_session_id: nil)
        raise NotImplementedError, "#{self.class} must implement #run"
      end
    end

    def self.parse_spec(raw, default_model: nil)
      text = raw.to_s.strip
      raise Error, "Backend spec cannot be empty" if text.empty?

      backend, model = text.split(":", 2)
      normalized = backend.strip.downcase
      normalized = "antigravity" if normalized == "agy"
      effective_model = model && !model.strip.empty? ? model.strip : default_model

      Spec.new(backend: normalized, model: effective_model)
    end

    def self.build(name, logger:, repo_root:)
      normalized = name.to_s.strip.downcase
      normalized = "antigravity" if normalized == "agy"

      case normalized
      when "codex"
        Codex.new(logger: logger, repo_root: repo_root)
      when "antigravity"
        Antigravity.new(logger: logger, repo_root: repo_root)
      when "gemini"
        Gemini.new(logger: logger, repo_root: repo_root)
      else
        raise Error, "Unsupported backend '#{name}'. Supported backends: codex, antigravity (agy), gemini"
      end
    end
  end
end
