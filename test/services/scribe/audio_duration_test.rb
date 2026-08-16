require "test_helper"
require "mocha/minitest"

module Scribe
  # Duration is what ASR is billed on, so "how many seconds is this blob" has to
  # be right without costing a second trip to S3. Production runs on the DO ruby
  # buildpack, which ships no ffprobe: Active Storage's audio analyzer finds
  # nothing there, so every duration falls through to this class.
  class AudioDurationTest < ActiveSupport::TestCase
    # A real (if silent) RIFF/WAVE file: the browser recorder emits exactly this
    # shape — 16-bit PCM, mono, 16 kHz — so byte_rate is 32_000 B/s.
    def wav_bytes(seconds:, sample_rate: 16_000, bits: 16, channels: 1)
      byte_rate = sample_rate * channels * bits / 8
      data_size = (byte_rate * seconds).to_i
      header = [
        "RIFF", 36 + data_size, "WAVE",
        "fmt ", 16, 1, channels, sample_rate, byte_rate, channels * bits / 8, bits,
        "data", data_size
      ].pack("a4Va4a4VvvVVvva4V")
      header + ("\0" * data_size)
    end

    def blob_for(bytes, content_type:, filename: "seg.wav")
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes), filename: filename, content_type: content_type
      )
    end

    test "measures a WAV exactly from its own header" do
      bytes = wav_bytes(seconds: 3)
      blob = blob_for(bytes, content_type: "audio/wav")

      result = AudioDuration.for_blob(blob, file: StringIO.new(bytes))

      assert_in_delta 3.0, result.seconds, 0.01
      assert_not result.estimated, "a header-derived duration is measured, not estimated"
    end

    test "does not re-download a segment it was already handed" do
      bytes = wav_bytes(seconds: 2)
      blob = blob_for(bytes, content_type: "audio/wav")
      blob.expects(:analyze).never
      blob.expects(:download).never

      result = AudioDuration.for_blob(blob, file: StringIO.new(bytes))

      assert_in_delta 2.0, result.seconds, 0.01
    end

    test "does not download at all when no file is supplied" do
      blob = blob_for(wav_bytes(seconds: 2), content_type: "audio/wav")
      blob.expects(:analyze).never
      blob.expects(:download).never

      result = AudioDuration.for_blob(blob)

      assert result.seconds.positive?
      assert result.estimated, "with no bytes in hand the duration can only be an estimate"
    end

    test "estimates a WAV at its PCM byte rate, not the compressed-audio rate" do
      # 10s of 16-bit 16kHz PCM. Without a WAV-aware rate this reads as 20s and
      # every segment is metered at twice its real length.
      blob = blob_for(wav_bytes(seconds: 10), content_type: "audio/wav")

      result = AudioDuration.for_blob(blob)

      assert_in_delta 10.0, result.seconds, 0.5
    end

    test "estimates a compressed segment from its byte size" do
      bytes = "not-really-webm" * 1000
      blob = blob_for(bytes, content_type: "audio/webm", filename: "seg.webm")

      result = AudioDuration.for_blob(blob, file: StringIO.new(bytes))

      assert result.estimated
      assert_in_delta bytes.bytesize / AudioDuration::ESTIMATE_BYTES_PER_SECOND,
                      result.seconds, 0.01
    end

    test "prefers a duration an analyzer already measured" do
      blob = blob_for(wav_bytes(seconds: 3), content_type: "audio/wav")
      blob.update!(metadata: blob.metadata.merge("duration" => 7.5, "analyzed" => true))

      result = AudioDuration.for_blob(blob)

      assert_in_delta 7.5, result.seconds, 0.01
      assert_not result.estimated
    end

    # TranscribeSegmentJob measures the segment and then streams the very same
    # handle to the ASR provider. Consuming it here would send a truncated file
    # (or an empty one) to Sarvam/Whisper and silently lose the audio.
    test "leaves the file readable from the start for the ASR call that follows" do
      bytes = wav_bytes(seconds: 1)
      blob = blob_for(bytes, content_type: "audio/wav")
      file = StringIO.new(bytes)

      AudioDuration.for_blob(blob, file: file)

      assert_equal 0, file.pos, "the ASR call reads from wherever we left the handle"
      assert_equal bytes.bytesize, file.read.bytesize, "the provider must still see the whole segment"
    end

    test "degrades to an estimate when the header is truncated or malformed" do
      bytes = "RIFF____WAVEgarbage"
      blob = blob_for(bytes, content_type: "audio/wav")

      result = AudioDuration.for_blob(blob, file: StringIO.new(bytes))

      assert result.estimated
      assert result.seconds >= 0
    end
  end
end
