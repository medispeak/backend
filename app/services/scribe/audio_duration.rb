module Scribe
  # Best-effort audio duration for per-minute ASR billing. Returns a Result with
  # `seconds` (Float) and `estimated` (Boolean). Never raises — a measurement
  # failure degrades to an estimate rather than aborting the pipeline. See
  # plan 001 for why: ASR is billed per minute and must not be metered at 0.
  class AudioDuration
    Result = Struct.new(:seconds, :estimated, keyword_init: true)

    # Rough bytes-per-second used only when no exact probe is available. Chosen
    # for a common compressed-audio bitrate; flagged estimated: true so the
    # UsageEvent is marked approximate. Adjust with maintainer guidance.
    ESTIMATE_BYTES_PER_SECOND = 16_000.0

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

    # Returns an exact duration in seconds when a probe is available, else nil.
    # If ffprobe is present, ActiveStorage's audio analyzer populates
    # blob.metadata["duration"]; otherwise this returns nil and we estimate.
    def exact_seconds
      @blob.analyze unless @blob.analyzed?
      @blob.metadata["duration"]&.to_f
    end

    def estimate_seconds
      (@blob.byte_size.to_f / ESTIMATE_BYTES_PER_SECOND).round(3)
    end
  end
end
