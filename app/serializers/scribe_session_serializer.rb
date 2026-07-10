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
      expires_at: @session.expires_at,
      transcript: serialize_transcript,
      outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
    }
  end

  private

  # Top-level transcript, sourced from the session's has_one :transcript so
  # clients read it without depending on output ordering (plan 021). Additive:
  # the per-output "transcript" output is still serialized unchanged, so the
  # SDK's extractTranscript keeps working. Plan 022 will populate this field
  # with the live (pre-commit) transcript — keep the "transcript" key name and
  # { text:, language: } shape stable.
  def serialize_transcript
    transcript = @session.transcript
    return nil if transcript.nil?

    { text: transcript.text, language: transcript.language }
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
