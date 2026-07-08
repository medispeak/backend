require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  PHI_KEYS = %i[context transcript transcription_text payload results note form audio audio_file].freeze

  # Assert redaction per key rather than array membership: Rails precompiles
  # config.filter_parameters in place into a single ORed Regexp the first time a
  # request is logged, so `assert_includes filters, :context` is order-dependent
  # (passes in isolation, fails once an integration test has run). Filtering
  # through a ParameterFilter tests the real behavior and is robust either way.
  test "each PHI-bearing param is redacted from logged params" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    PHI_KEYS.each do |key|
      filtered = filter.filter(key.to_s => "sensitive clinical value")
      assert_equal "[FILTERED]", filtered[key.to_s], "#{key} must be filtered from logs"
    end
  end

  test "a context value is redacted by the parameter filter" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("context" => "patient reports chest pain")

    assert_equal "[FILTERED]", filtered["context"]
  end

  test "a nested transcript value is redacted by the parameter filter" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("outputs" => [ { "transcript" => "full clinical note" } ])

    assert_equal "[FILTERED]", filtered["outputs"].first["transcript"]
  end
end
