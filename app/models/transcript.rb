class Transcript < ApplicationRecord
  belongs_to :scribe_session

  # A human replaced the text after ASR/OCR produced it.
  def edited?
    edited_at.present?
  end

  # original_text is set on the first correction only, so it always preserves
  # what the model actually produced regardless of later edits.
  def apply_correction!(new_text, by: nil)
    self.original_text = text if original_text.nil?
    update!(text: new_text, edited_at: Time.current, edited_by_user_id: by&.id)
  end
end
