# What a session's audio IS, for playback.
#
# Two ingest paths leave the recording in two different shapes, and the UI has
# to play both:
#
#   * audio_files — the canonical blob. Either a single-shot upload, or the
#     stitched result of the chunked path: Scribe::AudioSource concatenates the
#     chunks into audio_files at commit precisely so there is something durable
#     to play later. This is the whole recording, silence and all.
#   * transcript_segments — the streaming path (SDK, playground). Each segment
#     is a standalone, independently decodable clip of SPEECH ONLY, because the
#     client's VAD dropped the quiet between them. No assembled blob exists.
#
# audio_files wins when both are present: it is the recording itself rather than
# the speech cut out of it. Raw ScribeAudioChunks are deliberately never offered
# — every chunk after the first is a headerless continuation that no player can
# open on its own, and by commit time they have become audio_files anyway.
module AudioPlayback
  extend ActiveSupport::Concern

  # One playable piece of the recording. `source` + `source_id` are what the
  # audio endpoint resolves back into a blob; everything else is what the player
  # needs to draw a timeline BEFORE it has fetched a single byte.
  Part = Struct.new(:source, :source_id, :duration_seconds, :byte_size,
                    :content_type, :filename, :text, keyword_init: true) do
    def duration_known?
      duration_seconds.to_f.positive?
    end
  end

  # Ordered playable audio, or []. Memoized because the show page asks more than
  # once and each call walks the attachments.
  def audio_parts
    return @audio_parts if defined?(@audio_parts)

    @audio_parts = modality_document? ? [] : (file_parts.presence || segment_parts)
  end

  def audio_available?
    audio_parts.any?
  end

  # Total seconds, or nil when it cannot honestly be known from what is
  # persisted — the player then asks the browser rather than printing a number
  # we made up. Summed only when EVERY part reports a length; otherwise the
  # transcript's own figure stands in, which for the single-blob case is the
  # only measure taken of that audio at all.
  def audio_total_seconds
    parts = audio_parts
    return nil if parts.empty?
    return parts.sum { |part| part.duration_seconds.to_f } if parts.all?(&:duration_known?)

    persisted = transcript&.duration_seconds.to_f
    persisted.positive? ? persisted : nil
  end

  private

  def file_parts
    audio_files.map do |file|
      blob = file.blob
      Part.new(
        source: "file",
        source_id: file.id,
        byte_size: blob&.byte_size,
        content_type: blob&.content_type,
        filename: blob&.filename.to_s
      )
    end
  end

  # An unsettled segment has no duration yet but still has audio worth hearing,
  # so it is included with a nil length rather than hidden. Ordered and filtered
  # in Ruby so an eager-loaded association is reused instead of re-queried —
  # same reason the controller sorts rather than adding an `.order`.
  def segment_parts
    transcript_segments
      .select { |segment| segment.data.attached? }
      .sort_by(&:seq)
      .map do |segment|
        blob = segment.data.blob
        Part.new(
          source: "segment",
          source_id: segment.id,
          duration_seconds: segment.duration_seconds,
          byte_size: blob&.byte_size,
          content_type: segment.content_type.presence || blob&.content_type,
          filename: blob&.filename.to_s,
          text: segment.text.presence
        )
      end
  end
end
