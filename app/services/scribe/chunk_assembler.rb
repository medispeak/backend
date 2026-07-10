require "tempfile"

module Scribe
  # Concatenates a session's uploaded audio chunks (in seq order) into one blob
  # attached to session.audio_files, so the existing Orchestrator path runs
  # unchanged. Content-type comes from the lowest-seq chunk (defaulting to
  # audio/webm), which must be in ScribeSession::ALLOWED_AUDIO_TYPES.
  module ChunkAssembler
    module_function

    def assemble!(session)
      chunks = session.audio_chunks.order(:seq).to_a
      return false if chunks.empty?

      content_type = chunks.first.content_type.presence || "audio/webm"
      tmp = Tempfile.new([ "scribe_audio", ".bin" ])
      tmp.binmode
      chunks.each { |c| tmp.write(c.data.download) }
      tmp.rewind
      session.audio_files.attach(io: tmp, filename: "consultation", content_type: content_type)
      tmp.close!
      true
    end
  end
end
