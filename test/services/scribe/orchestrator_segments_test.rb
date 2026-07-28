require "test_helper"
require "mocha/minitest"

# ONE transcript-source rule: a session with transcription segments is
# assembled from those segments ONLY. The committed clinical transcript must
# NEVER silently drop audio (partial concatenation) NOR silently substitute a
# whole-file re-transcription for the segment transcript the clinician already
# saw live. A segment set that did not fully settle is an EXPLICIT failure
# naming the unsettled seqs, and a re-commit retries exactly those segments.
class OrchestratorSegmentsTest < ActiveSupport::TestCase
  ASR_URL = "https://api.openai.com/v1/audio/transcriptions".freeze

  setup do
    @session = create(:scribe_session, language: "en")
    @session.audio_files.attach(io: StringIO.new("whole-audio"), filename: "a.mp3", content_type: "audio/mpeg")
  end

  def done_segment(seq, text)
    @session.transcript_segments.create!(seq: seq, status: "done", text: text,
      language: "en", provider: "openai", model: "whisper-1", duration_seconds: 3.0)
  end

  def unsettled_segment(seq, status)
    seg = @session.transcript_segments.create!(seq: seq, status: status)
    seg.data.attach(io: StringIO.new("seg-bytes"), filename: "s.webm", content_type: "audio/webm")
    seg
  end

  test "all-done segments assemble by concatenation with no whole-file ASR call" do
    done_segment(0, "hello")
    done_segment(1, "doctor")

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "hello doctor", @session.transcript.text
    assert_not_requested :post, ASR_URL
  end

  test "assembly is never metered — done segments were billed on arrival" do
    done_segment(0, "hello")
    done_segment(1, "doctor")

    Scribe::Orchestrator.new(@session).call

    assert_equal 0, UsageEvent.where(scribe_session_id: @session.id, function: "asr").count
  end

  test "an unsettled segment is an explicit failure naming the seq, never a whole-file fallback" do
    done_segment(0, "first part")
    unsettled_segment(1, "transcribing")

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "failed", @session.status
    assert_nil @session.transcript, "no partial or substitute transcript may be persisted"
    assert_includes @session.error["message"], "segment(s) 1"
    assert_not_requested :post, ASR_URL
  end

  test "a failed segment fails the session with every output failed and no ASR charge" do
    done_segment(0, "first part")
    unsettled_segment(1, "failed")
    output = create(:scribe_output, scribe_session: @session, output_type: "transcript")

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "failed", @session.status
    assert output.reload.status_failure?
    assert_equal 0, UsageEvent.where(scribe_session_id: @session.id, function: "asr").count
    assert_not_requested :post, ASR_URL
  end

  test "a session without segments still runs whole-file ASR and meters it once" do
    stub_request(:post, ASR_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { text: "whole file transcript" }.to_json
    )

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "whole file transcript", @session.transcript.text
    assert_requested :post, ASR_URL, times: 1
    assert_equal 1, UsageEvent.where(scribe_session_id: @session.id, function: "asr").count
  end
end
