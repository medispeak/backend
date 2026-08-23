require "test_helper"
require "mocha/minitest"

class TranscribeSegmentJobTest < ActiveSupport::TestCase
  ASR_URL = "https://api.openai.com/v1/audio/transcriptions".freeze

  setup do
    @session = create(:scribe_session, account: create(:account), language: "en")
  end

  def stub_asr(text:)
    stub_request(:post, ASR_URL).to_return(
      status: 200,
      body: { text: text }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def add_segment(seq: 0, status: "pending", attempt: 0)
    segment = @session.transcript_segments.create!(seq: seq, status: status, attempt: attempt,
                                                   content_type: "audio/webm")
    segment.data.attach(io: StringIO.new("fake audio"), filename: "seg#{seq}.webm",
                        content_type: "audio/webm")
    segment
  end

  test "transcribes a pending segment and marks it done" do
    stub_asr(text: "the patient has a fever")
    segment = add_segment

    TranscribeSegmentJob.perform_now(segment.id)

    segment.reload
    assert_equal "done", segment.status
    assert_equal "the patient has a fever", segment.text
  end

  test "skips a segment another runner already claimed" do
    segment = add_segment(status: "transcribing")

    TranscribeSegmentJob.perform_now(segment.id)

    assert_equal "transcribing", segment.reload.status
    assert_not_requested :post, ASR_URL
  end

  # ProcessScribeSessionJob's stale-claim reclaim bumps `attempt` to hand the
  # segment to a fresh run. A slow-but-alive original must not then overwrite
  # the newer result with its own.
  test "a superseded run does not overwrite the result that replaced it" do
    stub_asr(text: "stale result")
    segment = add_segment

    # The reclaim lands while this run is mid-provider-call.
    Scribe::AsrStage.any_instance.stubs(:call).with do |*|
      ScribeTranscriptSegment.where(id: segment.id)
                             .update_all(status: "done", attempt: 1, text: "winning result")
      true
    end.returns(Scribe::AsrStage::Result.new(
                  text: "stale result", language: "en", provider: "openai",
                  model: "whisper-1", duration_seconds: 1.0, usage: nil
                ))

    TranscribeSegmentJob.perform_now(segment.id)

    segment.reload
    assert_equal "winning result", segment.text,
                 "the superseded run must not clobber the newer transcription"
    assert_equal 1, segment.attempt
  end

  # The superseded provider call really happened, so its spend must still reach
  # the ledger — under its own key, not colliding with the run that replaced it.
  test "a superseded run still bills its own provider call" do
    stub_asr(text: "stale result")
    segment = add_segment

    Scribe::AsrStage.any_instance.stubs(:call).with do |*|
      ScribeTranscriptSegment.where(id: segment.id)
                             .update_all(status: "done", attempt: 1, text: "winning result")
      true
    end.returns(Scribe::AsrStage::Result.new(
                  text: "stale result", language: "en", provider: "openai",
                  model: "whisper-1", duration_seconds: 1.0, usage: nil
                ))

    TranscribeSegmentJob.perform_now(segment.id)

    keys = @session.usage_events.pluck(:dedupe_key)
    assert_includes keys, Metering::DedupeKey.segment(@session.id, segment.id, 0)
  end

  test "a retried attempt bills under a distinct dedupe key" do
    stub_asr(text: "first pass")
    segment = add_segment
    TranscribeSegmentJob.perform_now(segment.id)

    segment.reload.update!(status: "pending", attempt: 1)
    TranscribeSegmentJob.perform_now(segment.id)

    keys = @session.usage_events.pluck(:dedupe_key)
    assert_includes keys, Metering::DedupeKey.segment(@session.id, segment.id, 0)
    assert_includes keys, Metering::DedupeKey.segment(@session.id, segment.id, 1)
    assert_equal keys.uniq.length, keys.length, "each physical attempt bills exactly once"
  end

  test "marks the segment failed when the provider errors" do
    stub_request(:post, ASR_URL).to_return(status: 500, body: "boom")
    segment = add_segment

    assert_nothing_raised { TranscribeSegmentJob.perform_now(segment.id) }
    assert_equal "failed", segment.reload.status
  end
end
