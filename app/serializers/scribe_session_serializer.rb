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
      outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
    }
  end

  private

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
