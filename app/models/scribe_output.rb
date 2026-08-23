class ScribeOutput < ApplicationRecord
  belongs_to :scribe_session
  belongs_to :page, optional: true

  enum :output_type, {
    transcript: "transcript",
    form: "form",
    note: "note"
  }

  # prefix: true so status methods/scopes (status_pending?, status_success?,
  # ...) never collide with output_type's (transcript?, form?, note?). Both
  # enums coexist cleanly.
  enum :status, {
    pending: "pending",
    success: "success",
    partial: "partial",
    failure: "failure"
  }, prefix: true

  validates :output_type, presence: true
  validates :status, presence: true

  # Prior answers kept per output; bounded so retry loops cannot grow the row
  # without limit.
  MAX_RESULT_HISTORY = 10

  # Archives the current answer and returns the output to :pending so the
  # orchestrator recomputes it. `attempt` feeds the metering dedupe_key: each
  # recomputation is a distinct billable provider call.
  def reset_for_retry!
    update!(
      previous_results: archived_results,
      attempt: attempt + 1,
      result: {},
      result_errors: [],
      status: :pending
    )
  end

  # Per-output errors are stored in the `result_errors` jsonb column. A column
  # named `errors` would collide with ActiveModel's reserved `errors` method and
  # raise ActiveRecord::DangerousAttributeError, preventing the class from
  # loading at all. The v2 API serializer maps `result_errors` to `errors` in
  # the JSON response.

  private

  # An output that never produced anything adds no history entry.
  def archived_results
    return previous_results if status_pending? && result.blank?

    entry = {
      "attempt" => attempt,
      "status" => status,
      "result" => result,
      "errors" => result_errors,
      "replaced_at" => Time.current.iso8601
    }
    (previous_results + [ entry ]).last(MAX_RESULT_HISTORY)
  end
end
