require "tempfile"

module Scribe
  # Yields a rewound local Tempfile of the FULL session audio and always closes
  # it. Downloads the audio content EXACTLY ONCE:
  #   - if session.audio_files is attached (single-shot upload, or a prior
  #     reassembly): download that blob once.
  #   - else if chunks exist: stream each chunk (in seq order) into ONE tempfile
  #     — the only read of the content — then attach that SAME tempfile to
  #     session.audio_files for durable storage/playback and reuse it for ASR.
  # Never downloads the assembled blob back for ASR.
  module AudioSource
    module_function

    # Yields a Tempfile (or nil when the session has neither a blob nor chunks).
    def with_audio(session)
      blob = session.audio_files.first
      if blob
        yield_blob(blob) { |io| return yield(io) }
      elsif session.audio_chunks.exists?
        yield_assembled(session) { |io| return yield(io) }
      else
        yield(nil)
      end
    end

    def yield_blob(blob)
      tmp = Tempfile.new([ "audio", extension_for(blob.filename.to_s, blob.content_type) ])
      tmp.binmode
      tmp.write(blob.download)
      tmp.rewind
      begin
        yield tmp
      ensure
        tmp.close!
      end
    end

    def yield_assembled(session)
      chunks = session.audio_chunks.order(:seq).to_a
      content_type = chunks.first.content_type.presence || "audio/webm"
      tmp = Tempfile.new([ "scribe_audio", extension_for(nil, content_type) ])
      tmp.binmode
      chunks.each { |c| tmp.write(c.data.download) } # the ONLY read of the content
      tmp.rewind
      # Attach the SAME bytes for durable storage/playback (choice A). Attaching
      # from the tempfile — not re-downloading a blob — keeps the content read once.
      session.audio_files.attach(io: tmp, filename: "consultation", content_type: content_type)
      tmp.rewind
      begin
        yield tmp
      ensure
        tmp.close!
      end
    end

    # Whisper infers format from the file extension, so the tempfile must carry a
    # real audio extension — never ".bin". Prefer the filename extension; fall
    # back to the content-type. Mirrors Orchestrator#audio_extension.
    CONTENT_TYPE_EXT = {
      "audio/mpeg" => ".mp3", "audio/mp3" => ".mp3", "audio/mp4" => ".mp4",
      "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/webm" => ".webm",
      "audio/ogg" => ".ogg", "audio/m4a" => ".m4a", "audio/aac" => ".aac"
    }.freeze

    def extension_for(filename, content_type)
      from_name = File.extname(filename.to_s).downcase
      return from_name if from_name.present?

      CONTENT_TYPE_EXT[content_type] || ".mp3"
    end
  end
end
