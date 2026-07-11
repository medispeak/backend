require "test_helper"
require "mocha/minitest"

# Segment-assembly safety net (plan 022 / audit 026): the committed clinical
# transcript must NEVER silently drop audio. A segment left unsettled at commit
# — failed, or orphaned in 'transcribing' by a killed worker that outlived the
# inline wait — must trigger a whole-file fallback for full coverage, not a
# partial concatenation of only the done segments.
class OrchestratorSegmentsTest < ActiveSupport::TestCase
  ASR_URL = "https://api.openai.com/v1/audio/transcriptions".freeze

  setup do
    Scribe::Incremental.stubs(:enabled?).returns(true)
    @session = create(:scribe_session, language: "en")
    @session.audio_files.attach(io: StringIO.new("whole-audio"), filename: "a.mp3", content_type: "audio/mpeg")
  end

  def done_segment(seq, text)
    @session.transcript_segments.create!(seq: seq, status: "done", text: text,
      language: "en", provider: "openai", model: "whisper-1", duration_seconds: 3.0)
  end

  # A segment already attached + claimed but never settled (dead worker).
  def stuck_segment(seq)
    seg = @session.transcript_segments.create!(seq: seq, status: "transcribing")
    seg.data.attach(io: StringIO.new("seg-bytes"), filename: "s.webm", content_type: "audio/webm")
    seg
  end

  def stub_whole_file(text: "the complete consultation transcript")
    stub_request(:post, ASR_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { text: text }.to_json
    )
  end

  test "a segment stuck in 'transcribing' triggers a whole-file fallback (no silent drop)" do
    done_segment(0, "first part")
    stuck = stuck_segment(1)
    stub_whole_file(text: "the complete consultation transcript")

    # Keep the stuck segment 'transcribing' through the bounded wait: no worker
    # settles it, so finish_incomplete_segments!'s wait times out and it stays
    # unsettled — the exact dead-worker orphan.
    Scribe::Orchestrator.any_instance.stubs(:wait_for_segment).returns(stuck)

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "the complete consultation transcript", @session.transcript.text,
                 "must re-transcribe the whole file, NOT concatenate only the done segment"
    refute_equal "first part", @session.transcript.text
    assert_requested :post, ASR_URL, times: 1
  end

  test "all-done segments assemble by concatenation with no whole-file ASR call" do
    done_segment(0, "hello")
    done_segment(1, "doctor")

    Scribe::Orchestrator.new(@session).call

    @session.reload
    assert_equal "hello doctor", @session.transcript.text
    assert_not_requested :post, ASR_URL
  end

  test "the whole-file fallback is NOT metered when a done (billed) segment exists" do
    done_segment(0, "billed part")
    stuck = stuck_segment(1)
    stub_whole_file
    Scribe::Orchestrator.any_instance.stubs(:wait_for_segment).returns(stuck)

    Scribe::Orchestrator.new(@session).call

    assert_equal 0, UsageEvent.where(scribe_session_id: @session.id, function: "asr").count,
                 "a done segment is the billed quantity; the completeness fallback must not double-charge"
  end
end
