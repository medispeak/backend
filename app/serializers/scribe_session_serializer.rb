# Plain-Ruby serializer for the v2 ScribeSession resource. Maps each output's
# `result_errors` column to the public JSON key "errors" (the column cannot be
# named `errors` without colliding with ActiveModel's reserved method).
class ScribeSessionSerializer
  def initialize(session)
    @session = session
  end

  def as_json(*)
    {
      id: @session.id,
      status: @session.status,
      mode: @session.mode,
      language: @session.language,
      created_at: @session.created_at,
      expires_at: @session.expires_at,
      transcript: serialize_transcript,
      outputs: @session.scribe_outputs.map { |output| serialize_output(output) },
      usage: serialize_usage
    }
  end

  private

  # Per-session metering so a client (the account's own user, via their account
  # token) can see what this session cost — not just the internal admin. Summed
  # in Ruby from the loaded usage_events association (preloaded on the index) so
  # a session list stays free of an N+1.
  def serialize_usage
    events = @session.usage_events.to_a
    {
      cost: events.sum { |e| e.cost.to_f },
      total_tokens: events.sum { |e| e.total_tokens.to_i },
      audio_seconds: events.sum { |e| e.audio_seconds.to_f },
      by_function: events.group_by(&:function)
                         .transform_values { |es| es.sum { |e| e.cost.to_f } }
    }
  end

  # Top-level transcript, sourced from the session's has_one :transcript so
  # clients read it without depending on output ordering (plan 021). Additive:
  # the per-output "transcript" output is still serialized unchanged, so the
  # SDK's extractTranscript keeps working. Keep the "transcript" key name and
  # { text:, language: } shape stable.
  #
  # Post-commit the persisted Transcript is authoritative; DURING recording
  # (plan 022) fall back to the growing live transcript assembled from the done
  # segments, tagged with the session's language hint. nil when neither exists.
  def serialize_transcript
    transcript = @session.transcript
    return { text: transcript.text, language: transcript.language } if transcript

    live = @session.live_transcript
    return nil if live.blank?

    { text: live, language: @session.language }
  end

  def serialize_output(output)
    {
      id: output.id,
      type: output.output_type,
      status: output.status,
      result: output.result,
      errors: output.result_errors
    }
  end
end
