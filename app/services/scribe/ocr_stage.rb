module Scribe
  # The OCR function: lab-report documents (PDF/images) -> the full extracted
  # text. Provider-agnostic; wraps Llm::Caller.ocr (which owns provider
  # fallback). The page count is supplied by the caller (counted at upload
  # time) because providers do not report it and OCR carries a per-page price
  # component.
  #
  # Extraction only — structuring runs afterwards through the normal
  # StructuringStage against the extracted text, exactly like an audio
  # transcript. The prompt demands a faithful transcription (tables as
  # markdown), never a summary: the persisted text is the audit trail of what
  # the model read off the report.
  class OcrStage
    Result = Struct.new(
      :text, :pages, :model, :provider, :usage, :raw,
      keyword_init: true
    )

    DEFAULT_PROMPT = <<~PROMPT.freeze
      Transcribe the complete text content of the attached medical document(s)
      exactly as written. Preserve the reading order. Render tables as GitHub
      markdown tables. Include every value, unit, and reference range. Do not
      summarize, interpret, or omit anything. Output only the transcribed text.
    PROMPT

    def initialize(config:)
      @config = config
    end

    # documents: [{ data:, content_type:, filename: }], pages: total page count.
    def call(documents, pages: 0)
      llm = Llm::Caller.ocr(@config, documents: documents, prompt: DEFAULT_PROMPT)

      Result.new(
        text: llm.text,
        pages: pages,
        model: llm.model,
        provider: llm.provider,
        usage: usage_with_pages(llm.usage, pages),
        raw: llm.raw
      )
    end

    private

    # Adapters normalize token usage but know nothing about page counts; graft
    # the caller-supplied count on so metering prices the per-page component.
    def usage_with_pages(usage, pages)
      return Llm::Usage.new(pages: pages, estimated: true) if usage.nil?

      Llm::Usage.new(
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        audio_seconds: usage.audio_seconds,
        pages: pages,
        estimated: usage.estimated
      )
    end
  end
end
