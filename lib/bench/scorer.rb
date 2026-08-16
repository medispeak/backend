module Bench
  # Field-level scoring of a structured extraction against a fixture's
  # `expected` values. Default is exact match after normalization; a fixture
  # can relax individual keys via `scoring`:
  #   "exact"                        default
  #   "contains:<substr>"            free-text contains the (normalized) substring
  #   "any_of:<a>|<b>|<c>"           any of these normalized values is acceptable
  #   "number_tolerance:<abs>"       numbers within +/- abs are acceptable
  # Booleans compare as booleans, multi_select as case-insensitive sets, and an
  # expected null is correct only when the model also returned null/blank.
  module Scorer
    Result = Struct.new(:key, :expected, :actual, :correct, :rule, keyword_init: true)

    RULES = %w[exact contains any_of number_tolerance].freeze
    NEEDS_ARG = %w[contains any_of number_tolerance].freeze

    def self.score(expected:, actual:, rules: {})
      actual ||= {}
      results = expected.map do |key, exp|
        rule = (rules || {})[key].to_s.presence || "exact"
        validate_rule!(key, rule)
        act = actual[key.to_s]
        Result.new(key: key, expected: exp, actual: act, rule: rule, correct: match?(exp, act, rule))
      end
      total = results.size
      correct = results.count(&:correct)
      { fields: results, total: total, correct: correct, accuracy: total.zero? ? 1.0 : (correct.to_f / total).round(4) }
    end

    # A typo'd rule ("contain:fever") or a blank argument would otherwise fall
    # through to a silently wrong comparison and be blamed on the model.
    def self.validate_rule!(key, rule)
      kind, arg = rule.split(":", 2)
      raise ArgumentError, "unknown scoring rule #{rule.inspect} for #{key}" unless RULES.include?(kind)
      raise ArgumentError, "scoring rule #{rule.inspect} for #{key} needs an argument" if NEEDS_ARG.include?(kind) && arg.to_s.strip.empty?
    end

    def self.match?(expected, actual, rule)
      return blank?(actual) if expected.nil?
      return false if actual.nil?

      kind, arg = rule.split(":", 2)
      case kind
      when "contains" then norm(actual).include?(norm(arg))
      when "any_of" then arg.to_s.split("|").map { |v| norm(v) }.include?(norm(actual))
      when "number_tolerance"
        n = to_number(actual)
        e = to_number(expected)
        !n.nil? && !e.nil? && (n - e).abs <= arg.to_f + 1e-9
      else
        exact?(expected, actual)
      end
    end

    def self.exact?(expected, actual)
      case expected
      when Array
        return false unless actual.is_a?(Array)

        expected.map { |v| norm(v) }.sort == actual.map { |v| norm(v) }.sort
      when Numeric
        n = to_number(actual)
        !n.nil? && (n - expected).abs < 1e-9
      when TrueClass, FalseClass
        return actual == expected if actual == true || actual == false

        %w[true yes false no].include?(norm(actual)) && (%w[true yes].include?(norm(actual)) == expected)
      else
        norm(expected) == norm(actual)
      end
    end

    def self.blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
    end

    def self.norm(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end

    def self.to_number(value)
      case value
      when Numeric then value.to_f
      when String then Float(value.strip) rescue nil
      end
    end
  end
end
