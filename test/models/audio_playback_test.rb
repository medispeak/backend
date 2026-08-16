require "test_helper"

# What the player is handed. The rules that matter are which of the two ingest
# shapes wins, what order the parts come back in, and — most of all — when a
# total duration is refused rather than guessed.
class AudioPlaybackTest < ActiveSupport::TestCase
  setup do
    @session = create(:scribe_session)
  end

  def attach_file(session, name: "consultation.mp3", bytes: "audio")
    session.audio_files.attach(io: StringIO.new(bytes), filename: name, content_type: "audio/mpeg")
  end

  def create_segment(session, seq:, duration: nil, text: nil, status: "done", attached: true)
    segment = session.transcript_segments.create!(
      seq: seq, duration_seconds: duration, text: text, status: status, content_type: "audio/wav"
    )
    segment.data.attach(io: StringIO.new("wav"), filename: "#{seq}.wav", content_type: "audio/wav") if attached
    segment
  end

  # --- What counts as playable ------------------------------------------------

  test "a session with nothing attached has no audio" do
    assert_empty @session.audio_parts
    assert_not @session.audio_available?
    assert_nil @session.audio_total_seconds
  end

  test "attached audio files become parts" do
    attach_file(@session)

    part = @session.audio_parts.sole
    assert_equal "file", part.source
    assert_equal "audio/mpeg", part.content_type
    assert @session.audio_available?
  end

  test "segments become parts in seq order, not insertion order" do
    create_segment(@session, seq: 2, text: "second")
    create_segment(@session, seq: 0, text: "zeroth")
    create_segment(@session, seq: 1, text: "first")

    assert_equal %w[zeroth first second], @session.audio_parts.map(&:text)
    assert_equal [ "segment" ], @session.audio_parts.map(&:source).uniq
  end

  test "a segment with no attached audio is not a part" do
    create_segment(@session, seq: 0, text: "kept")
    create_segment(@session, seq: 1, text: "no bytes", attached: false)

    assert_equal [ "kept" ], @session.audio_parts.map(&:text)
  end

  # The stored blob is the whole recording; the segments are the speech cut out
  # of it. When both exist the whole recording wins.
  test "audio files win over segments when a session has both" do
    attach_file(@session)
    create_segment(@session, seq: 0, text: "speech only")

    assert_equal [ "file" ], @session.audio_parts.map(&:source)
  end

  test "a document session offers no audio even if something is attached" do
    session = create(:scribe_session, modality: "document")
    attach_file(session)

    assert_empty session.audio_parts
    assert_not session.audio_available?
  end

  # --- Duration ---------------------------------------------------------------

  test "total is the sum when every part reports a length" do
    create_segment(@session, seq: 0, duration: 4.5)
    create_segment(@session, seq: 1, duration: 3.25)

    assert_in_delta 7.75, @session.audio_total_seconds, 0.001
  end

  test "an unsettled segment leaves the total to the transcript" do
    create_segment(@session, seq: 0, duration: 4.5)
    create_segment(@session, seq: 1, duration: nil, status: "pending")
    create(:transcript, scribe_session: @session, duration_seconds: 12)

    assert_in_delta 12, @session.audio_total_seconds, 0.001
  end

  # The alternative is printing 4.5 seconds for a recording that is longer than
  # that, which is worse than printing nothing and asking the browser.
  test "total is nil when neither the parts nor the transcript know" do
    create_segment(@session, seq: 0, duration: 4.5)
    create_segment(@session, seq: 1, duration: nil, status: "pending")

    assert_nil @session.audio_total_seconds
  end

  test "a stored blob has no length of its own so the transcript supplies it" do
    attach_file(@session)
    create(:transcript, scribe_session: @session, duration_seconds: 90)

    assert_nil @session.audio_parts.sole.duration_seconds
    assert_in_delta 90, @session.audio_total_seconds, 0.001
  end
end
