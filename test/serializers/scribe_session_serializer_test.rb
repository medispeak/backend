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

  # A billed-but-unusable attempt is in the ledger as :failed but is not charged
  # to the customer, so the session's usage — what the customer reads as their
  # cost — must not include it. Otherwise a session that failed outright would
  # report a cost, contradicting the API's "a run that produced nothing costs
  # nothing".
  test "usage sums finalized events only, never failed attempts" do
    session = create(:scribe_session, modality: "document")
    UsageEvent.create!(account: session.account, scribe_session: session, function: "ocr",
                       status: "failed", cost: 0.02, total_tokens: 5000, pages: 3,
                       input_tokens: 900, output_tokens: 4100)
    UsageEvent.create!(account: session.account, scribe_session: session, function: "ocr",
                       status: "finalized", cost: 0.01, total_tokens: 1200, pages: 3,
                       input_tokens: 900, output_tokens: 300)
    UsageEvent.create!(account: session.account, scribe_session: session, function: "structuring",
                       status: "finalized", cost: 0.001, total_tokens: 400,
                       input_tokens: 350, output_tokens: 50)

    usage = ScribeSessionSerializer.new(session.reload).as_json[:usage]
    assert_in_delta 0.011, usage[:cost], 1e-9
    assert_equal 1600, usage[:total_tokens]
    assert_equal 3, usage[:pages]
    assert_in_delta 0.01, usage[:by_function]["ocr"], 1e-9
    assert_in_delta 0.001, usage[:by_function]["structuring"], 1e-9
  end
end
