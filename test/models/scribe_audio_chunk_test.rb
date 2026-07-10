require "test_helper"

class ScribeAudioChunkTest < ActiveSupport::TestCase
  test "belongs to a scribe_session and holds an attached data blob" do
    session = create(:scribe_session)
    chunk = session.audio_chunks.create!(seq: 0, content_type: "audio/webm")
    chunk.data.attach(io: StringIO.new("bytes"), filename: "c0", content_type: "audio/webm")

    assert_equal session, chunk.scribe_session
    assert chunk.data.attached?
    assert_equal "bytes", chunk.data.download
  end

  test "requires a non-negative integer seq" do
    session = create(:scribe_session)
    assert_not session.audio_chunks.build(seq: nil).valid?
    assert_not session.audio_chunks.build(seq: -1).valid?
    assert session.audio_chunks.build(seq: 0).valid?
  end

  test "seq is unique per session" do
    session = create(:scribe_session)
    session.audio_chunks.create!(seq: 0)
    dup = session.audio_chunks.build(seq: 0)
    assert_not dup.valid?
    assert_includes dup.errors[:seq], "has already been taken"
  end

  test "the same seq may exist across different sessions" do
    session_a = create(:scribe_session)
    session_b = create(:scribe_session)
    session_a.audio_chunks.create!(seq: 0)
    assert session_b.audio_chunks.build(seq: 0).valid?
  end

  test "destroying the session destroys its chunks" do
    session = create(:scribe_session)
    session.audio_chunks.create!(seq: 0)
    assert_difference("ScribeAudioChunk.count", -1) { session.destroy }
  end
end
