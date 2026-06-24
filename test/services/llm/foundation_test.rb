# Standalone unit tests for the pure-Ruby Llm foundation.
# Runnable without Rails/DB: `ruby -Itest test/services/llm/foundation_test.rb`
# (Also picked up by `bin/rails test` once the app boots.)
require "minitest/autorun"

# Standalone mode loads the files directly; under `bin/rails test` Rails is
# already booted and Zeitwerk autoloads these constants, so skip the manual load.
unless defined?(Rails)
  base = File.expand_path("../../../app/services/llm", __dir__)
  require_relative "#{base}/usage"
  require_relative "#{base}/result"
  require_relative "#{base}/error"
  require_relative "#{base}/timeout"
  require_relative "#{base}/rate_limited"
  require_relative "#{base}/bad_response"
  require_relative "#{base}/config"
  require_relative "#{base}/default_config_provider"
end

class LlmFoundationTest < Minitest::Test
  def test_usage_totals_and_defaults
    u = Llm::Usage.new(input_tokens: 10, output_tokens: 5)
    assert_equal 15, u.total_tokens
    assert_equal 0.0, u.audio_seconds
    refute u.estimated
  end

  def test_usage_estimated_flag_and_audio
    u = Llm::Usage.new(audio_seconds: 42, estimated: true)
    assert_equal 42.0, u.audio_seconds
    assert u.estimated
    assert_equal 0, u.total_tokens
  end

  def test_result_carries_usage_and_fields
    r = Llm::Result.new(text: "hi", provider: "openai_compatible", usage: Llm::Usage.new(input_tokens: 1))
    assert_equal "hi", r.text
    assert_equal "openai_compatible", r.provider
    assert_equal 1, r.usage.total_tokens
  end

  def test_error_hierarchy
    assert Llm::Timeout.ancestors.include?(Llm::Error)
    assert Llm::RateLimited.ancestors.include?(Llm::Error)
    assert Llm::BadResponse.ancestors.include?(Llm::Error)
    assert Llm::Error.ancestors.include?(StandardError)
  end

  def test_config_lazy_api_key_via_resolver
    calls = 0
    cfg = Llm::Config.new(
      provider_kind: :openai_compatible, api_model_id: "m", base_url: "http://x/",
      api_key_resolver: -> { calls += 1; "sk-resolved" }
    )
    assert_equal 0, calls, "resolver must not run at construction"
    assert_equal "sk-resolved", cfg.api_key
    assert_equal 1, calls
  end

  def test_config_capability_predicate
    cfg = Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "m",
                          base_url: "http://x/", capabilities: { can_transcribe: true })
    assert cfg.capability?(:can_transcribe)
    refute cfg.capability?(:can_structure)
  end

  def test_default_config_provider_structuring_from_env
    with_env("OPENAI_ACCESS_TOKEN" => "sk-abc", "OPENAI_ORGANIZATION_ID" => "org-1") do
      cfg = Llm::DefaultConfigProvider.call(function: :structuring)
      assert_equal :openai_compatible, cfg.provider_kind
      assert_equal "gpt-4o-mini", cfg.api_model_id
      assert_equal "https://api.openai.com/", cfg.base_url
      assert_equal "org-1", cfg.organization_id
      assert_equal "sk-abc", cfg.api_key
      assert cfg.capability?(:supports_json_schema)
    end
  end

  def test_default_config_provider_asr_defaults
    cfg = Llm::DefaultConfigProvider.call(function: :asr)
    assert_equal "whisper-1", cfg.api_model_id
    assert cfg.capability?(:can_transcribe)
    assert cfg.capability?(:accepts_audio)
  end

  def test_default_config_provider_passes_fallback
    fb = Llm::DefaultConfigProvider.call(function: :structuring)
    cfg = Llm::DefaultConfigProvider.call(function: :structuring, fallback: fb)
    assert_same fb, cfg.fallback
  end

  private

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV[k]; ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
