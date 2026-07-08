require "test_helper"

class ScribeSessionTest < ActiveSupport::TestCase
  test "valid with an account and status" do
    assert build(:scribe_session).valid?
  end

  test "requires a status" do
    session = build(:scribe_session)
    session.status = nil
    refute session.valid?
    assert_includes session.errors[:status], "can't be blank"
  end

  test "belongs to an account" do
    account = create(:account)
    session = create(:scribe_session, account: account)
    assert_equal account, session.account
  end

  test "api_token and user are optional" do
    session = build(:scribe_session, api_token: nil, user: nil)
    assert session.valid?
  end

  test "status enum exposes all states" do
    expected = %w[created uploading processing completed partial failed expired]
    assert_equal expected.sort, ScribeSession.statuses.keys.sort
  end

  test "status enum predicates work" do
    session = build(:scribe_session, status: "processing")
    assert session.processing?
    refute session.completed?
  end

  test "mode enum exposes dictation and consultation" do
    assert_equal %w[dictation consultation].sort, ScribeSession.modes.keys.sort
  end

  test "mode defaults to consultation" do
    session = create(:scribe_session)
    assert_equal "consultation", session.mode
    assert session.consultation?
  end

  test "expired? is false when expires_at is in the future" do
    session = build(:scribe_session, expires_at: 1.day.from_now)
    refute session.expired?
  end

  test "expired? is true when expires_at is in the past" do
    session = build(:scribe_session, expires_at: 1.minute.ago)
    assert session.expired?
  end

  test "expired? is false when expires_at is nil" do
    session = build(:scribe_session, expires_at: nil)
    refute session.expired?
  end

  test "has many scribe_outputs destroyed with the session" do
    session = create(:scribe_session)
    create(:scribe_output, scribe_session: session)
    assert_difference("ScribeOutput.count", -1) { session.destroy }
  end

  test "has one transcript destroyed with the session" do
    session = create(:scribe_session)
    create(:transcript, scribe_session: session)
    assert_difference("Transcript.count", -1) { session.destroy }
  end

  test "supports attaching audio files" do
    session = create(:scribe_session)
    session.audio_files.attach(
      io: StringIO.new("fake audio bytes"),
      filename: "recording.wav",
      content_type: "audio/wav"
    )
    assert session.audio_files.attached?
    assert_equal 1, session.audio_files.count
    assert_equal "recording.wav", session.audio_files.first.filename.to_s
  end

  test "rejects a non-https callback_url" do
    session = build(:scribe_session, callback_url: "http://example.com/webhook")
    assert_not session.valid?
    assert_match(/https/, session.errors[:callback_url].join)
  end

  test "rejects a loopback callback_url" do
    session = build(:scribe_session, callback_url: "https://127.0.0.1/webhook")
    assert_not session.valid?
  end

  test "rejects the cloud-metadata callback_url" do
    session = build(:scribe_session, callback_url: "https://169.254.169.254/latest/meta-data")
    assert_not session.valid?
  end

  test "rejects a private RFC-1918 callback_url" do
    session = build(:scribe_session, callback_url: "https://10.0.0.5/webhook")
    assert_not session.valid?
  end

  test "accepts a public https callback_url" do
    session = build(:scribe_session, callback_url: "https://client.example.com/webhook")
    assert session.valid?
  end

  test "accepts a blank callback_url" do
    session = build(:scribe_session, callback_url: nil)
    assert session.valid?
  end
end
