require "test_helper"

# ScribeSession#claim_modality — the moment an undeclared session becomes an
# audio one or a document one.
class ScribeSessionModalityTest < ActiveSupport::TestCase
  test "a pending session is claimed by the first caller" do
    session = create(:scribe_session, modality: "pending")

    assert session.claim_modality("document")
    assert_equal "document", session.reload.modality
  end

  test "claiming the modality a session already has is a no-op that succeeds" do
    session = create(:scribe_session, modality: "audio")

    assert session.claim_modality("audio")
    assert_equal "audio", session.reload.modality
  end

  test "claiming the other modality on a decided session fails without changing it" do
    session = create(:scribe_session, modality: "audio")

    assert_not session.claim_modality("document")
    assert_equal "audio", session.reload.modality
  end

  # One session token can drive all four upload surfaces at once. With a
  # read-check-write both claimants passed `modality_pending?` and the second
  # overwrote the first, leaving a session holding BOTH kinds of content while
  # claiming to be one of them — the orchestrator then transcribes only the
  # winner's kind, and segments already uploaded were metered on arrival for a
  # transcript nobody reads. Exactly one claimant may win.
  test "two concurrent claimants: exactly one wins and the loser is told" do
    session = create(:scribe_session, modality: "pending")
    audio_side = ScribeSession.find(session.id)
    document_side = ScribeSession.find(session.id)

    first = audio_side.claim_modality("audio")
    second = document_side.claim_modality("document")

    assert first, "the first claimant should win"
    assert_not second, "the second claimant must lose, not overwrite"
    assert_equal "audio", session.reload.modality
    # The loser's own object reflects reality, so the controller 409s with the
    # modality the session actually has rather than the one it wanted.
    assert_equal "audio", document_side.modality
  end

  test "the loser of a race sees the winning modality even in the other order" do
    session = create(:scribe_session, modality: "pending")
    audio_side = ScribeSession.find(session.id)
    document_side = ScribeSession.find(session.id)

    assert document_side.claim_modality("document")
    assert_not audio_side.claim_modality("audio")
    assert_equal "document", session.reload.modality
    assert_equal "document", audio_side.modality
  end
end
