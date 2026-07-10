# A STANDALONE, independently-decodable transcription segment uploaded during
# recording (plan 022). Separate from ScribeAudioChunk (the storage stream): a
# segment is transcribed on arrival by TranscribeSegmentJob through the same
# provider ASR seam, and the final transcript is assembled from the ordered
# segment texts. The `status` column carries the enum (prefixed predicates:
# status_done? / status_failed?) so the async job and the commit-time inline
# pass can atomically claim a segment via a conditional UPDATE.
class ScribeTranscriptSegment < ApplicationRecord
  belongs_to :scribe_session
  has_one_attached :data

  enum :status, {
    pending: "pending",
    transcribing: "transcribing",
    done: "done",
    failed: "failed"
  }, prefix: true

  validates :seq, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            uniqueness: { scope: :scribe_session_id }
end
