class ScribeAudioChunk < ApplicationRecord
  belongs_to :scribe_session
  has_one_attached :data

  validates :seq, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            uniqueness: { scope: :scribe_session_id }
end
