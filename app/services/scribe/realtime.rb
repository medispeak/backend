module Scribe
  # Toggle for the realtime voice path: the browser connects DIRECTLY to the
  # realtime provider (OpenAI) using a short-lived ephemeral token minted by the
  # backend, so the account key never reaches the client. OFF by default — the
  # realtime_token endpoint 404s until flipped with ENV["SCRIBE_REALTIME"].
  #
  # Realtime is a live-transcription OVERLAY during recording; the authoritative
  # transcript + structuring still come from the existing commit pipeline, so
  # turning this on never changes committed results.
  module Realtime
    def self.enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["SCRIBE_REALTIME"])
    end
  end
end
