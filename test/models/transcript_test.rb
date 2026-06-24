require "test_helper"

class TranscriptTest < ActiveSupport::TestCase
  test "valid with a scribe_session" do
    assert build(:transcript).valid?
  end

  test "requires a scribe_session" do
    transcript = build(:transcript, scribe_session: nil)
    refute transcript.valid?
  end

  test "belongs to a scribe_session" do
    session = create(:scribe_session)
    transcript = create(:transcript, scribe_session: session)
    assert_equal session, transcript.scribe_session
  end

  test "persists jsonb segments, words, and speakers" do
    transcript = create(
      :transcript,
      segments: [ { "start" => 0, "end" => 2, "text" => "hello" } ],
      words: [ { "word" => "hello", "start" => 0, "end" => 1 } ],
      speakers: [ { "id" => "spk_1", "label" => "Doctor" } ]
    )
    transcript.reload
    assert_equal "hello", transcript.segments.first["text"]
    assert_equal "hello", transcript.words.first["word"]
    assert_equal "Doctor", transcript.speakers.first["label"]
  end

  test "jsonb collection columns default to empty arrays" do
    session = create(:scribe_session)
    transcript = Transcript.create!(scribe_session: session)
    assert_equal [], transcript.segments
    assert_equal [], transcript.words
    assert_equal [], transcript.speakers
  end

  test "duration_seconds preserves three decimal places" do
    transcript = create(:transcript, duration_seconds: 12.345)
    transcript.reload
    assert_equal BigDecimal("12.345"), transcript.duration_seconds
  end
end
