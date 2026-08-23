class ScribeSession < ApplicationRecord
  # Which of this session's stored audio can actually be played back, and in
  # what order. See the concern for why that is not simply "the attachments".
  include AudioPlayback

  belongs_to :account
  belongs_to :api_token, optional: true
  belongs_to :user, optional: true

  has_many :scribe_outputs, dependent: :destroy
  has_many :audio_chunks, class_name: "ScribeAudioChunk", dependent: :destroy
  has_many :transcript_segments, class_name: "ScribeTranscriptSegment", dependent: :destroy
  has_one :transcript, dependent: :destroy
  # Metering ledger for this session. Nullify (not destroy) so the immutable
  # usage record survives even if the session is purged; used by the admin view.
  has_many :usage_events, dependent: :nullify

  has_many_attached :audio_files
  has_many_attached :document_files

  # Audio upload allowlist + ceiling. The API controllers reject bad uploads
  # before attaching (with a surface-appropriate error); these attachment
  # validations are defense-in-depth for any other write path. Spoofing
  # protection is off, so this checks the declared content-type — a first-line
  # guard against a huge or non-audio payload reaching storage/ASR (plan 014).
  ALLOWED_AUDIO_TYPES = %w[
    audio/mpeg audio/mp4 audio/wav audio/x-wav audio/webm audio/ogg audio/m4a audio/aac
  ].freeze
  MAX_AUDIO_BYTES = 25.megabytes

  # Document (OCR modality) allowlist + ceilings. Pages are counted at upload
  # time (pdf-reader; images count as one page) and accumulated in
  # document_pages so both the page cap and per-page metering are cheap.
  ALLOWED_DOCUMENT_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze
  MAX_DOCUMENT_BYTES = 20.megabytes
  MAX_DOCUMENT_FILE_BYTES = 10.megabytes
  MAX_DOCUMENT_PAGES = 20

  validates :audio_files,
            content_type: ALLOWED_AUDIO_TYPES,
            size: { less_than_or_equal_to: MAX_AUDIO_BYTES }
  validates :document_files,
            content_type: ALLOWED_DOCUMENT_TYPES,
            size: { less_than_or_equal_to: MAX_DOCUMENT_BYTES }

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

  # What kind of source this session ingests: recorded audio (ASR) or an
  # uploaded lab report / document (vision OCR). Prefixed predicates
  # (modality_audio? / modality_document?) keep the bare audio-ish names free.
  # "pending" is server-managed (SessionBuilder::CLIENT_MODALITIES): a caller
  # who declares nothing gets it, and #claim_modality fixes it on first upload.
  enum :modality, { pending: "pending", audio: "audio", document: "document" }, prefix: :modality

  validates :status, presence: true
  validate :callback_url_is_safe

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  # Fixes an undeclared session's modality to the surface of its first stored
  # upload. Returns false when a concurrent first upload claimed the other one.
  #
  # Conditional UPDATE, not a read-check-write: one token can drive all four
  # upload surfaces at once, and two claimants both passing `modality_pending?`
  # would leave a session holding audio AND documents.
  def claim_modality(kind)
    return true if modality == kind.to_s
    return false unless modality_pending?

    self.class.where(id: id, modality: "pending")
        .update_all(modality: kind.to_s, updated_at: Time.current)
    reload
    modality == kind.to_s
  end

  # The growing transcript DURING recording: the done segments' texts, in seq
  # order, joined. nil once committed (the persisted Transcript is then
  # authoritative) or before any segment finishes ASR.
  #
  # Guarded to uploading/processing only so created and terminal sessions never
  # touch the segments association — this keeps the index endpoint's N+1 guard
  # green. Computed in Ruby from the (preloadable) loaded association, not via a
  # .where query, so an eager-loaded relation is reused instead of re-queried.
  def live_transcript
    return nil unless uploading? || processing?

    transcript_segments.select(&:status_done?)
                       .sort_by(&:seq)
                       .map(&:text)
                       .reject(&:blank?)
                       .join(" ")
                       .presence
  end

  private

  # First line only: the address is re-checked and pinned at delivery time,
  # because DNS can change between here and then (Scribe::WebhookTarget).
  def callback_url_is_safe
    return if callback_url.blank?

    uri = Scribe::WebhookTarget.https_uri(callback_url)
    unless uri
      errors.add(:callback_url, "must be a valid https URL")
      return
    end

    if Scribe::WebhookTarget.unsafe_host?(uri.hostname)
      errors.add(:callback_url, "must not point to a private, loopback, or link-local address")
    end
  end
end
