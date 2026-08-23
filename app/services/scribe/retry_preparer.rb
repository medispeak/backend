module Scribe
  # Prepares a finished session to run through the pipeline again. Retry adds no
  # second pipeline: this invalidates what should be recomputed, the caller
  # re-enters the normal claim -> hold -> ProcessScribeSessionJob path, and the
  # orchestrator's "skip successful outputs" rule redoes exactly what was reset.
  #
  #   structuring   - keep the transcript (optionally correcting it), re-fill.
  #   transcription - rebuild the transcript from the audio, then re-fill.
  #
  # No "all" scope: a transcript output is an echo of the transcript, so
  # regenerating the transcript already implies regenerating everything.
  class RetryPreparer
    SCOPES = %w[structuring transcription].freeze

    # Retries per output on top of the original commit (attempt 0).
    MAX_ATTEMPTS = 3

    # A corrected transcript goes straight into the structuring prompt.
    MAX_TRANSCRIPT_CHARS = 100_000

    # created/uploading belong to a first commit; processing is already running.
    RETRYABLE_STATUSES = %w[completed partial failed].freeze

    def initialize(session:, scope:, transcript: nil, user: nil)
      @session = session
      @scope = scope.to_s
      @transcript_text = transcript
      @user = user
    end

    # The first failing check as { code:, message:, status: }, or nil. Runs
    # before the caller claims the session, so a rejection never needs undoing.
    def validate
      validate_scope || validate_status || validate_transcript || validate_attempts
    end

    def call
      ScribeSession.transaction do
        session.transcript.apply_correction!(@transcript_text, by: @user) if transcript_edit?

        if transcription?
          session.transcript&.destroy!
          reset_segments!
        end

        targeted_outputs.each(&:reset_for_retry!)
      end
      session
    end

    private

    attr_reader :session

    def transcription?
      @scope == "transcription"
    end

    def transcript_edit?
      @transcript_text.present?
    end

    def validate_scope
      error("scope must be one of: #{SCOPES.join(', ')}") unless SCOPES.include?(@scope)
    end

    def validate_status
      return if RETRYABLE_STATUSES.include?(session.status)

      error("Session cannot be retried from status #{session.status}", status: :conflict)
    end

    def validate_transcript
      return unless @transcript_text

      # Re-transcribing would overwrite the caller's correction — reject the
      # combination rather than silently dropping one half.
      if transcription?
        return error("transcript cannot be supplied with scope=transcription; " \
                     "re-transcribing would discard the correction")
      end
      return error("transcript must be a string") unless @transcript_text.is_a?(String)
      return error("transcript cannot be blank") if @transcript_text.strip.empty?

      if @transcript_text.length > MAX_TRANSCRIPT_CHARS
        return error("transcript exceeds the #{MAX_TRANSCRIPT_CHARS}-character limit")
      end

      error("this session has no transcript to correct") if session.transcript.nil?
    end

    def validate_attempts
      return if targeted_outputs.none? { |output| output.attempt >= MAX_ATTEMPTS }

      error("This session has reached the retry limit of #{MAX_ATTEMPTS}",
            code: "retry_limit_exceeded", status: :too_many_requests)
    end

    def error(message, code: "validation_error", status: :unprocessable_entity)
      { code: code, message: message, status: status }
    end

    # Back to :pending, which TranscribeSegmentJob's pending/failed claim can
    # take again; an in-flight :transcribing claim is left alone.
    def reset_segments!
      session.transcript_segments.where.not(status: "transcribing").find_each do |segment|
        segment.update!(status: "pending", attempt: segment.attempt + 1)
      end
    end

    # A transcript output is an echo, so it only re-runs when the text it
    # echoes changed (re-derived or corrected).
    def targeted_outputs
      @targeted_outputs ||=
        if transcription? || transcript_edit?
          session.scribe_outputs.to_a
        else
          session.scribe_outputs.reject(&:transcript?)
        end
    end
  end
end
