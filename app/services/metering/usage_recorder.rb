module Metering
  # Persists a UsageEvent from a normalized Llm::Result. Prices the call via
  # PriceBook, snapshots the unit prices, and records normalized token/audio
  # usage. Defensive against a nil result.usage (e.g. a provider that omitted
  # its usage block).
  class UsageRecorder
    class << self
      def record(account:, function:, result:, api_token: nil, scribe_session: nil,
                 scribe_output: nil, status: :finalized, dedupe_key: nil)
        usage = result&.usage
        provider = result&.provider
        model = result&.model

        pricing = PriceBook.cost(
          function: function,
          provider: provider,
          model: model,
          usage: usage
        )

        UsageEvent.create!(
          account: account,
          api_token: api_token,
          # Acting-user attribution for per-user limits and rollups: the
          # session's clinician when present, else the token's owner.
          user_id: scribe_session&.user_id || api_token&.user_id,
          scribe_session_id: scribe_session&.id,
          scribe_output_id: scribe_output&.id,
          function: function.to_s,
          provider: provider,
          model: model,
          input_tokens: usage&.input_tokens.to_i,
          output_tokens: usage&.output_tokens.to_i,
          total_tokens: usage&.total_tokens.to_i,
          audio_seconds: usage&.audio_seconds.to_f,
          pages: usage&.pages.to_i,
          estimated: usage ? !!usage.estimated : false,
          unit_price_input: pricing[:unit_price_input],
          unit_price_output: pricing[:unit_price_output],
          unit_price_audio_min: pricing[:unit_price_audio_min],
          unit_price_page: pricing[:unit_price_page],
          cost: pricing[:cost],
          currency: pricing[:currency],
          latency_ms: result&.latency_ms,
          status: status.to_s,
          dedupe_key: dedupe_key
        )
      end
    end
  end
end
