module Scribe
  # Best-effort audio duration for per-minute ASR billing. Returns a Result with
  # `seconds` (Float) and `estimated` (Boolean). Never raises — a measurement
  # failure degrades to an estimate rather than aborting the pipeline. See
  # plan 001 for why: ASR is billed per minute and must not be metered at 0.
  #
  # This deliberately never touches storage. It used to call `blob.analyze`,
  # which downloads the blob a SECOND time (the caller already holds the bytes)
  # and then shells out to ffprobe — a binary the production buildpack does not
  # ship, so the download bought nothing. Duration now comes from the bytes in
  # hand: the audio's own header when it is a format we can read, else a
  # byte-rate estimate.
  class AudioDuration
    Result = Struct.new(:seconds, :estimated, keyword_init: true)

    # Rough bytes-per-second used only when no exact probe is available. Chosen
    # for a common compressed-audio bitrate; flagged estimated: true so the
    # UsageEvent is marked approximate. Adjust with maintainer guidance.
    ESTIMATE_BYTES_PER_SECOND = 16_000.0

    # Uncompressed PCM is ~2x the compressed rate, so estimating a WAV with the
    # constant above bills every segment at twice its real length. This is the
    # browser recorder's own format (16-bit, mono, 16 kHz -> 32_000 B/s) and is
    # only ever reached when a WAV's header cannot be parsed; a well-formed WAV
    # is measured exactly.
    WAV_ESTIMATE_BYTES_PER_SECOND = 32_000.0

    # Bound the header scan so a malformed or hostile file cannot make us walk a
    # long chunk list. A real WAV carries `data` within the first few chunks.
    MAX_HEADER_CHUNKS = 16

    def self.for_blob(blob, file: nil)
      new(blob, file: file).call
    end

    def initialize(blob, file: nil)
      @blob = blob
      @file = file
    end

    def call
      exact = exact_seconds
      return Result.new(seconds: exact, estimated: false) if exact&.positive?

      Result.new(seconds: estimate_seconds, estimated: true)
    rescue StandardError
      Result.new(seconds: estimate_seconds, estimated: true)
    end

    private

    # An exact duration when one can be had without going back to storage: a
    # duration some analyzer already recorded (environments that do have
    # ffprobe), otherwise the audio's own header.
    def exact_seconds
      recorded = @blob.metadata["duration"]&.to_f
      return recorded if recorded&.positive?

      header_seconds
    end

    # Duration read from the file the caller already downloaded. nil when there
    # is no file in hand or the bytes are not a readable WAV, which sends the
    # caller to the estimate.
    def header_seconds
      return nil if @file.nil?
      return nil unless wav?

      wav_seconds(@file)
    end

    def estimate_seconds
      rate = wav? ? WAV_ESTIMATE_BYTES_PER_SECOND : ESTIMATE_BYTES_PER_SECOND
      (@blob.byte_size.to_f / rate).round(3)
    end

    def wav?
      type = @blob.content_type.to_s.downcase
      type.include?("wav") || @blob.filename.to_s.downcase.end_with?(".wav")
    end

    # Parse a RIFF/WAVE header: duration is the `data` chunk's size divided by
    # the `fmt ` chunk's byte rate. Reads only the header — never the samples —
    # and always leaves the IO where it found it, because the caller streams the
    # very same handle to the ASR provider next.
    def wav_seconds(io)
      original_pos = io.pos
      io.rewind

      return nil unless io.read(4) == "RIFF"

      io.read(4) # total size, unused
      return nil unless io.read(4) == "WAVE"

      byte_rate = nil
      data_size = nil

      MAX_HEADER_CHUNKS.times do
        header = io.read(8)
        break if header.nil? || header.bytesize < 8

        chunk_id = header[0, 4]
        chunk_size = header[4, 4].unpack1("V")
        break if chunk_size.nil?

        case chunk_id
        when "fmt "
          fmt = io.read(chunk_size)
          break if fmt.nil? || fmt.bytesize < 16

          # audio_format(2) channels(2) sample_rate(4) byte_rate(4)
          byte_rate = fmt[8, 4].unpack1("V")
        when "data"
          data_size = chunk_size
          break # samples follow; everything needed is known
        else
          # Chunks are word-aligned, so an odd size carries one pad byte.
          io.seek(chunk_size + (chunk_size.odd? ? 1 : 0), IO::SEEK_CUR)
        end

        break if byte_rate && data_size
      end

      return nil if byte_rate.nil? || byte_rate.zero? || data_size.nil?

      (data_size.to_f / byte_rate).round(3)
    rescue StandardError
      nil
    ensure
      io.seek(original_pos) if io.respond_to?(:seek)
    end
  end
end
