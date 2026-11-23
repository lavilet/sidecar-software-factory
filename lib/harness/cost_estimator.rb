module Harness
  # Estimates USD cost and aggregates token usage across harness stages.
  class CostEstimator
    DEFAULT_RATES = [ 2.50, 0.25, 10.00 ].freeze

    def initialize(config_file:)
      @pricing = config_file.pricing
    end

    def estimate_usd(model:, usage:)
      return 0.0 unless usage.is_a?(Hash)

      input_rate, cached_rate, output_rate = rates_for(model)
      input = usage.fetch("input_tokens", 0).to_i
      cached = usage.fetch("cached_input_tokens", 0).to_i
      uncached_input = [ input - cached, 0 ].max
      output = usage.fetch("output_tokens", 0).to_i

      cost = (uncached_input * input_rate + cached * cached_rate + output * output_rate) / 1_000_000.0
      cost.round(5)
    end

    def self.empty_usage
      {
        "input_tokens" => 0,
        "cached_input_tokens" => 0,
        "output_tokens" => 0,
        "reasoning_tokens" => 0,
        "total_tokens" => 0
      }
    end

    def self.merge_usage(usages)
      totals = empty_usage
      Array(usages).compact.each do |u|
        totals["input_tokens"] += u.fetch("input_tokens", 0).to_i
        totals["cached_input_tokens"] += u.fetch("cached_input_tokens", 0).to_i
        totals["output_tokens"] += u.fetch("output_tokens", 0).to_i
        totals["reasoning_tokens"] += u.fetch("reasoning_tokens", 0).to_i
      end
      totals["total_tokens"] = totals["input_tokens"] + totals["output_tokens"]
      totals
    end

    def self.cache_hit_ratio(usage)
      input = usage.fetch("input_tokens", 0).to_i
      return 0.0 if input <= 0

      (usage.fetch("cached_input_tokens", 0).to_f / input).round(3)
    end

    private
    def rates_for(model)
      key = model.to_s.strip
      raw = @pricing[key] || @pricing["default"]
      return DEFAULT_RATES unless raw

      parts = raw.split(",").map { |v| v.strip.to_f }
      parts.size == 3 ? parts : DEFAULT_RATES
    end
  end
end
