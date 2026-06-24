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

    def call(transcript_text)
      model_schema = builder.call
      llm = Llm::Caller.structure(@config, messages: messages(transcript_text), schema: model_schema)
      guard_completion!(llm)

      data, errors = validator.validate_and_repair(llm.structured) do |errs|
        repair(transcript_text, model_schema, llm.structured, errs)
      end

      Result.new(
        structured: data,
        usage: llm.usage,
        model: llm.model,
        provider: llm.provider,
        finish_reason: llm.finish_reason,
        valid: errors.empty?,
        errors: errors
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
