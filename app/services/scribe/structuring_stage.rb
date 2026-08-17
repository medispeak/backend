module Scribe
  # The Structuring function: transcript text + a page's field definitions ->
  # a validated structured object. Provider-agnostic — it composes SchemaBuilder
  # (model + validation schemas), Llm::Caller (provider call + fallback), and
  # SchemaValidator (enforce constraints the decoder ignores + one repair).
  #
  # Inputs are plain (fields/context/system_prompt/config) so this is unit-
  # testable with stubbed HTTP and no database.
  class StructuringStage
    Result = Struct.new(
      :structured, :usage, :model, :provider, :finish_reason, :valid, :errors,
      :latency_ms, :repaired,
      keyword_init: true
    )

    # finish_reasons that mean the model completed normally.
    COMPLETE = %w[stop end_turn].freeze

    def initialize(config:, fields:, context: {}, system_prompt: nil)
      @config = config
      @fields = fields
      @context = context || {}
      @system_prompt = system_prompt
    end

    # `documents` structures directly from the source file — one vision call
    # instead of OCR-then-structure. The repair re-ask deliberately does NOT
    # re-send them: the previous JSON and the validation errors are already in
    # the repair prompt, so paying to re-read the document buys nothing.
    def call(transcript_text, documents: nil, max_tokens: nil)
      # Timed over the whole stage rather than taken from llm.latency_ms: a
      # failed validation triggers a repair re-ask, which is a SECOND provider
      # round-trip, and the first call's latency would silently undercount the
      # slowest runs — exactly the ones worth noticing when comparing models.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      repaired = false

      model_schema = builder.call
      llm = Llm::Caller.structure(
        @config,
        messages: messages(transcript_text), schema: model_schema,
        documents: documents, max_tokens: max_tokens
      )
      guard_completion!(llm)

      data, errors = validator.validate_and_repair(llm.structured) do |errs|
        repaired = true
        repair(transcript_text, model_schema, llm.structured, errs)
      end

      Result.new(
        structured: data,
        usage: llm.usage,
        model: llm.model,
        provider: llm.provider,
        finish_reason: llm.finish_reason,
        valid: errors.empty?,
        errors: errors,
        latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        # A model that needed a second pass to produce schema-valid JSON is a
        # weaker fit for this template than one that got it right first time,
        # even when both end up valid.
        repaired: repaired
      )
    end

    private

    def builder
      SchemaBuilder.new(fields: @fields, context: @context)
    end

    def validator
      SchemaValidator.new(builder.call(for_validation: true))
    end

    def messages(text)
      msgs = []
      msgs << { role: "system", content: @system_prompt } if present?(@system_prompt)
      msgs << { role: "user", content: text.to_s }
      msgs
    end

    # Truncation (length) or a refusal returns HTTP 200 with unusable content —
    # surface it instead of trusting the parsed body.
    def guard_completion!(llm)
      return if llm.finish_reason.nil? || COMPLETE.include?(llm.finish_reason.to_s)

      raise Llm::BadResponse, "model did not complete (finish_reason=#{llm.finish_reason})"
    end

    def repair(text, schema, previous, errors)
      repair_messages = messages(text) + [
        { role: "assistant", content: previous.to_json },
        { role: "user", content: "The previous output failed validation: " \
                                 "#{errors.map { |e| e[:message] }.join('; ')}. " \
                                 "Return corrected JSON only." }
      ]
      Llm::Caller.structure(@config, messages: repair_messages, schema: schema).structured
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
