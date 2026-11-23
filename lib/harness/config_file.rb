module Harness
  # Minimal stdlib TOML reader for profile config.toml ([roles] and [efforts]).
  class ConfigFile
    DEFAULT_ROLES = {
      "router" => "codex",
      "architect" => "codex",
      "worker" => "codex",
      "reviewers" => "codex,codex",
      "arbiter" => "codex",
      "qa" => "codex",
      "retro" => "codex",
      "scout" => "codex"
    }.freeze

    DEFAULT_EFFORTS = {
      "router" => "low",
      "architect" => "high",
      "worker" => "medium",
      "reviewer" => "medium",
      "arbiter" => "high",
      "qa" => "low",
      "retro" => "medium",
      "scout" => "low"
    }.freeze

    def self.load(repo_root)
      path = File.join(Harness::Paths.profile(File.expand_path(repo_root)), "config.toml")
      parsed = {}
      if File.exist?(path)
        section = nil
        File.readlines(path, chomp: true).each do |raw_line|
          line = raw_line.sub(/#.*\z/, "").strip
          next if line.empty?

          if (match = line.match(/\A\[([^\]]+)\]\z/))
            section = match[1].strip
            parsed[section] ||= {}
          elsif section && (kv = line.match(/\A([a-zA-Z0-9_.-]+)\s*=\s*(.+)\z/))
            parsed[section][kv[1]] = kv[2].strip.gsub(/\A"|"\z/, "")
          end
        end
      end

      new(
        roles: DEFAULT_ROLES.merge(parsed.fetch("roles", {})),
        efforts: DEFAULT_EFFORTS.merge(parsed.fetch("efforts", {})),
        budgets: parsed.fetch("budgets", {}),
        pricing: parsed.fetch("pricing", {})
      )
    end

    attr_reader :roles, :efforts, :budgets, :pricing

    def initialize(roles:, efforts:, budgets: {}, pricing: {})
      @roles = roles.freeze
      @efforts = efforts.freeze
      @budgets = budgets.freeze
      @pricing = pricing.freeze
    end

    def role(name)
      @roles.fetch(name.to_s)
    end

    def reviewer_specs
      role("reviewers").split(",").map(&:strip).reject(&:empty?)
    end

    def effort(name)
      @efforts[name.to_s]
    end

    def max_tokens_per_run
      @budgets.fetch("max_tokens_per_run", 600_000).to_i
    end

    def max_usd_per_run
      @budgets.fetch("max_usd_per_run", 2.0).to_f
    end
  end
end
