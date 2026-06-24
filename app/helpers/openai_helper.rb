# Thin controller glue between the v1 API and the model-agnostic Llm seam.
#
# This no longer talks to OpenAI directly: ASR goes through Scribe::AsrStage and
# structuring through Scribe::StructuringStage, both resolved from config
# (DefaultConfigProvider = today's OpenAI defaults until DB-backed config lands).
# The public method names, the ai_response shape, the additive token sums, and
# the GenericException error contract are preserved so v1 clients are unaffected.
module OpenaiHelper
  # mode defaults to :translate to preserve v1's English-transcript behavior.
  def ai_transcribe(file, mode: :translate, language: nil)
    validate_api_credentials
    config = Llm::DefaultConfigProvider.call(function: :asr)
    Scribe::AsrStage.new(config: config)
                    .call(File.open(file), mode: mode, language: language)
                    .text
  rescue Llm::Error => e
    handle_ai_error(e)
  end

  def system_prompt(transcription)
    return transcription.page.prompt if transcription.page.prompt.present?

    "You are an AI assistant filling the form for a user. Make sure that you do not " \
      "populate the form with any data that the user did not provide. Ensure all data " \
      "shared by users are correctly split into function arguments."
  end

  def ai_generate_completion(transcription)
    validate_api_credentials
    config = Llm::DefaultConfigProvider.call(function: :structuring)
    stage = Scribe::StructuringStage.new(
      config: config,
      fields: transcription.form_fields,
      context: transcription.context,
      system_prompt: system_prompt(transcription)
    )

    result = stage.call(transcription.transcription_text)
    transcription.update!(
      ai_response: result.structured || {},
      status: :completion_generated,
      **summed_usage(transcription, result.usage)
    )
  rescue Llm::Error => e
    transcription.update(status: :failed)
    handle_ai_error(e)
  end

  private

  # Preserves v1's additive token accounting on the transcription row.
  def summed_usage(transcription, usage)
    {
      prompt_tokens: usage.input_tokens + transcription.prompt_tokens,
      completion_tokens: usage.output_tokens + transcription.completion_tokens,
      total_tokens: usage.total_tokens + transcription.total_tokens
    }
  end

  def validate_api_credentials
    missing_keys = []
    missing_keys << "API key" unless ENV["OPENAI_ACCESS_TOKEN"].present?
    missing_keys << "Organization ID" unless ENV["OPENAI_ORGANIZATION_ID"].present?

    return if missing_keys.empty?

    raise GenericException.new(
      message: "OpenAI #{missing_keys.join(' and ')} is missing. Please set it in the " \
               "environment variable OPENAI_ACCESS_TOKEN and OPENAI_ORGANIZATION_ID.",
      code: :failed_dependency
    )
  end

  # Scrubs provider internals from the client-facing message (logs keep detail).
  def handle_ai_error(error)
    Rails.logger.error("LLM request failed: #{error.class}: #{error.message}")
    raise GenericException.new(
      message: "The AI request was unsuccessful. Please verify the provider configuration " \
               "and try again.",
      code: :failed_dependency
    )
  end
end
