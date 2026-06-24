class ScribeSession < ApplicationRecord
  belongs_to :account
  belongs_to :api_token, optional: true
  belongs_to :user, optional: true

  has_many :scribe_outputs, dependent: :destroy
  has_one :transcript, dependent: :destroy

  has_many_attached :audio_files

  enum :status, {
    created: "created",
    uploading: "uploading",
    processing: "processing",
    completed: "completed",
    partial: "partial",
    failed: "failed",
    expired: "expired"
  }

  # mode default is "consultation" (set at the column level). validate: false
  # keeps unknown/legacy modes from raising on read.
  enum :mode, { dictation: "dictation", consultation: "consultation" }, validate: false

  validates :status, presence: true

  def expired?
    expires_at.present? && expires_at < Time.current
  end
end
