require "tempfile"

# Transcribes ONE standalone ScribeTranscriptSegment through the provider-agnostic
# ASR seam (plan 022). Enqueued on segment arrival; also invoked inline
# (perform_now) at commit to finish a trailing segment.
#
# Both callers go through the SAME atomic claim below, so the async job and the
# commit-time inline pass can never both call the provider for one segment.
#
# ASR is metered best-effort per segment (record + deduct only — NEVER a hold: a
# credit check must not reject a segment mid-recording). On any failure the
# segment is marked "failed", logged, and swallowed — no re-raise, so a poison
# segment does not retry forever (mirrors ProcessScribeSessionJob).
class TranscribeSegmentJob < ApplicationJob
  def perform(segment_id)
    # ATOMIC claim: only one runner may move this segment into "transcribing".
    # A segment already "transcribing" or "done" matches zero rows here and is
    # skipped, so the async job and the commit-time inline pass never both call
    # the provider for the same segment.
    claimed = ScribeTranscriptSegment
              .where(id: segment_id, status: %w[pending failed])
              .update_all(status: "transcribing", updated_at: Time.current)
    return if claimed.zero?

    segment = ScribeTranscriptSegment.find_by(id: segment_id)
    return if segment.nil?

    session = segment.scribe_session
    config = Llm::ConfigResolver.call(function: :asr, account: session.account)
    blob = segment.data.blob

    result = with_segment_audio(segment, blob) do |io|
      duration = Scribe::AudioDuration.for_blob(blob, file: io).seconds
      Scribe::AsrStage.new(config: config).call(
        io,
        language: session.language,
        mode: config.asr_mode,
        audio_seconds: duration
      )
    end

    segment.update!(
      text: result.text,
      language: result.language,
      provider: result.provider,
      model: result.model,
      duration_seconds: result.duration_seconds,
      transcribed_at: Time.current,
      status: "done"
    )

    meter_segment(session, segment, result)
  rescue StandardError => e
    # Mark failed via update_all so this is robust whether or not `segment` was
    # loaded, and swallow — no infinite retry.
    ScribeTranscriptSegment.where(id: segment_id).update_all(status: "failed", updated_at: Time.current)
    Rails.logger.error("TranscribeSegmentJob failed for segment=#{segment_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  # Downloads the segment blob into a Tempfile that carries a REAL audio
  # extension (never ".bin", which Whisper rejects) and always closes it. Reuses
  # the shared Scribe::AudioSource.extension_for helper so the per-segment path
  # and the whole-file path infer the extension identically.
  def with_segment_audio(segment, blob)
    tmp = Tempfile.new([ "segment", Scribe::AudioSource.extension_for(segment.data.filename.to_s, segment.content_type) ])
    tmp.binmode
    tmp.write(blob.download)
    tmp.rewind
    begin
      yield tmp
    ensure
      tmp.close!
    end
  end

  # Best-effort ASR metering for one segment: record a usage_event and deduct it.
  # Mirrors Orchestrator#record_and_deduct but with a per-segment dedupe_key so a
  # retried job never double-charges. CRITICAL: record + deduct only — it must
  # NEVER place a credit reservation or hard-block here. A credit check must not
  # reject a segment mid-recording; billing is settled against the commit-time
  # reservation.
  def meter_segment(session, segment, result)
    event = Metering::UsageRecorder.record(
      account: session.account,
      function: :asr,
      result: as_llm_result(result),
      api_token: session.api_token,
      scribe_session: session,
      dedupe_key: "#{session.id}:segment:#{segment.id}:asr"
    )
    Metering::QuotaGuard.deduct!(event)
  rescue StandardError => e
    Rails.logger.error("TranscribeSegmentJob metering failed for segment=#{segment.id}: #{e.class}: #{e.message}")
    nil
  end

  # Adapts AsrStage::Result to the Llm::Result contract Metering::UsageRecorder
  # consumes (matches Orchestrator#as_llm_result). Per-segment latency is the
  # only ASR timing a live recording produces — the whole-file path never runs —
  # so dropping it here would leave every streamed session with no ASR timing.
  def as_llm_result(result)
    Llm::Result.new(
      text: result.text,
      structured: nil,
      model: result.model,
      provider: result.provider,
      usage: result.usage,
      latency_ms: result.respond_to?(:latency_ms) ? result.latency_ms : nil,
      finish_reason: nil,
      raw: result.respond_to?(:raw) ? result.raw : nil
    )
  end
end
