module Metering
  # Computes the provider cost for a single usage event from versioned price
  # tables. Returns a hash with the total cost plus the snapshotted unit prices
  # so the caller can persist them on the UsageEvent. Never raises on a missing
  # price row — it returns zeros so metering degrades gracefully.
  class PriceBook
    ROUNDING = 6

    class << self
      # Every amount here stays BigDecimal end to end: `cost` lands in a
      # decimal(12,6) column and is settled against the decimal credit ledger,
      # and binary floats cannot represent those fractions exactly.
      def cost(function:, provider:, model:, usage:, at: Time.current)
        function = function.to_sym
        total = BigDecimal(0)
        unit_price_input = nil
        unit_price_output = nil
        unit_price_audio_min = nil
        unit_price_page = nil
        currency = "USD"

        if audio?(function)
          audio_price = AudioModelPrice.current(at).find_by(provider: provider, model: model)
          if audio_price
            unit_price_audio_min = audio_price.price_per_minute
            currency = audio_price.currency || currency
            total += audio_cost(usage, audio_price)
          end
        end

        if tokens?(function)
          token_price = ModelPrice.current(at).find_by(provider: provider, model: model)
          if token_price
            unit_price_input = token_price.input_per_million
            unit_price_output = token_price.output_per_million
            currency = token_price.currency || currency
            total += token_cost(usage, token_price)
          end
        end

        if pages?(function)
          page_price = DocumentModelPrice.current(at).find_by(provider: provider, model: model)
          if page_price
            unit_price_page = page_price.price_per_page
            currency = page_price.currency || currency
            total += usage&.pages.to_i * decimal(page_price.price_per_page)
          end
        end

        {
          cost: total.round(ROUNDING),
          currency: currency,
          unit_price_input: unit_price_input,
          unit_price_output: unit_price_output,
          unit_price_audio_min: unit_price_audio_min,
          unit_price_page: unit_price_page
        }
      end

      private

      def audio?(function)
        function == :asr
      end

      # Vision providers bill OCR in tokens, so :ocr always consults the token
      # table; a DocumentModelPrice row adds an optional per-page component.
      def tokens?(function)
        function == :structuring || function == :ocr
      end

      def pages?(function)
        function == :ocr
      end

      def audio_cost(usage, price)
        (decimal(usage&.audio_seconds) / 60) * decimal(price.price_per_minute)
      end

      def token_cost(usage, price)
        per_million = BigDecimal(1_000_000)
        (usage&.input_tokens.to_i / per_million * decimal(price.input_per_million)) +
          (usage&.output_tokens.to_i / per_million * decimal(price.output_per_million))
      end

      # A missing price column bills nothing rather than raising — metering
      # degrades gracefully (see the class comment).
      def decimal(value)
        value.nil? ? BigDecimal(0) : value.to_d
      end
    end
  end
end
