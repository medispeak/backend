require "test_helper"

class ScribeSessionSerializerTest < ActiveSupport::TestCase
  test "top-level transcript is nil when the session has no transcript" do
    session = create(:scribe_session)
    json = ScribeSessionSerializer.new(session).as_json
    assert_nil json[:transcript]
  end

  test "top-level transcript mirrors the session's transcript when present" do
    session = create(:scribe_session, language: "en")
    Transcript.create!(
      scribe_session: session, text: "the patient has a fever",
      language: "en", provider: "openai_compatible", model: "whisper-1"
    )
    json = ScribeSessionSerializer.new(session.reload).as_json
    assert_equal "the patient has a fever", json[:transcript][:text]
    assert_equal "en", json[:transcript][:language]
  end
end
