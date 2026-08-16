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
      :text, :pages, :model, :provider, :usage, :raw, :latency_ms, :finish_reason,
      # Billed attempts Llm::Caller abandoned for the fallback provider. Passed
      # straight through so the orchestrator can meter them; see Llm::Result.
      :discarded_attempts,
      keyword_init: true
    )

    # Output budget for the transcription, sized from the page count the caller
    # already measured. The Anthropic adapter's shared DEFAULT_MAX_TOKENS is
    # 4096 — a STRUCTURING budget, and barely three pages of a dense lab report
    # — so OCR asks for its own rather than inheriting it. A lab-report page is
    # roughly 700-1500 tokens of markdown; 2000 leaves headroom for wide tables.
    # The floor covers an image upload (pages is 1) and the ceiling keeps a
    # spoofed page count from asking a provider for an absurd completion.
    TOKENS_PER_PAGE = 2000
    MIN_MAX_TOKENS = 4096
    MAX_MAX_TOKENS = 32_000

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
      llm = Llm::Caller.ocr(
        @config,
        documents: documents,
        prompt: DEFAULT_PROMPT,
        max_tokens: max_tokens_for(pages)
      )
      guard_completion!(llm)

      Result.new(
        text: llm.text,
        pages: pages,
        model: llm.model,
        provider: llm.provider,
        usage: usage_with_pages(llm.usage, pages),
        raw: llm.raw,
        latency_ms: llm.latency_ms,
        finish_reason: llm.finish_reason,
        discarded_attempts: llm.discarded
      )
    end

    private

    # Backstop, not the primary guard. Truncation is caught inside the adapters
    # (Llm::Adapter#guard_ocr_completion!), because only a raise during the
    # attempt is visible to Llm::Caller and can therefore spend the fallback
    # provider. This second check costs nothing and catches a future adapter
    # that implements #ocr without calling the shared guard — it fails the
    # session instead of persisting a half-transcribed report, having simply
    # missed the chance to fall back.
    def guard_completion!(llm)
      return if llm.finish_reason.nil? || Llm::Adapter::OCR_COMPLETE.include?(llm.finish_reason.to_s)

      raise Llm::BadResponse,
            "OCR did not complete (finish_reason=#{llm.finish_reason}); " \
            "the document was too long for the model's output budget"
    end

    def max_tokens_for(pages)
      (pages.to_i * TOKENS_PER_PAGE).clamp(MIN_MAX_TOKENS, MAX_MAX_TOKENS)
    end

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
