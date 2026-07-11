module Scribe
  # Structures the growing LIVE transcript for a session's form outputs DURING
  # recording, so a client can pre-fill the form before the clinician stops.
  # Returns the merged { key => value } across every form output.
  #
  # Reuses the same StructuringStage + ConfigResolver seam as the commit-time
  # pipeline (so the same model/provider applies). Interim passes are NOT
  # persisted or metered — they are a speculative UX assist; the authoritative,
  # metered fill still happens once at commit (Scribe::Orchestrator). Gated off
  # by default via Scribe::Incremental.live_form_enabled?.
  class LiveStructurer
    def initialize(session)
      @session = session
    end

    def call(transcript_text)
      return {} if transcript_text.blank?

      merged = {}
      form_outputs.each do |output|
        stage = structure(output, transcript_text)
        merged.merge!(stage.structured) if stage&.structured.is_a?(Hash)
      end
      merged
    end

    private

    def form_outputs
      @session.scribe_outputs.select { |o| o.output_type == "form" }
    end

    def structure(output, text)
      if output.inline_fields.present?
        fields = Scribe::InlineField.build_all(output.inline_fields)
        system_prompt = nil
      elsif output.page
        fields = output.page.form_fields.to_a
        system_prompt = output.page.prompt
      else
        return nil
      end

      config = Llm::ConfigResolver.call(
        function: :structuring, page: output.page, account: @session.account
      )
      Scribe::StructuringStage.new(
        config: config, fields: fields,
        context: output.context, system_prompt: system_prompt
      ).call(text)
    rescue StandardError => e
      # Best-effort: a live pass never breaks recording. The commit fill is
      # authoritative.
      Rails.logger.warn(
        "LiveStructurer session=#{@session.id} output=#{output.id}: #{e.class}: #{e.message}"
      )
      nil
    end
  end
end
