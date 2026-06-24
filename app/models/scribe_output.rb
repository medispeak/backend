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

  # Per-output errors are stored in the `result_errors` jsonb column. A column
  # named `errors` would collide with ActiveModel's reserved `errors` method and
  # raise ActiveRecord::DangerousAttributeError, preventing the class from
  # loading at all. The v2 API serializer maps `result_errors` to `errors` in
  # the JSON response.
end
