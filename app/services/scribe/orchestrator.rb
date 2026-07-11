module Scribe
  # Composes the cascaded scribe pipeline for one ScribeSession:
  #
  #   1. ASR ONCE (shared across all outputs): audio -> Transcript, persisted on
  #      the session. Metered as function: :asr and deducted from the ledger. If
  #      ASR fails there is nothing to structure, so the session and every output
  #      are marked failed and we return early.
  #   2. For EACH scribe_output, isolated (one output's failure never aborts a
  #      sibling): produce its result from the shared transcript.
  #        - transcript: echo the transcript text/language.
  #        - form:       run StructuringStage against the page's form fields.
  #        - note:       run StructuringStage against a synthetic single "note"
  #                      field in free-text mode.
  #   3. Roll up the session status: completed (all success), partial (mixed),
  #      or failed (all failed).
  #
  # Metering follows the design spec: one usage_event per physical attempt,
  # recorded then deducted. Per-output errors live in `result_errors` (NOT
  # `errors`, which is reserved by ActiveModel).
  class Orchestrator
    # Synthetic field used for free-text note generation. Duck-types FormField
    # for SchemaBuilder/StructuringStage (responds to the 7 schema methods).
    NoteField = Struct.new(
      :title, :friendly_name, :description, :field_type,
      :enum_options, :minimum, :maximum,
      keyword_init: true
    )

    NOTE_KEY = "note".freeze

    def initialize(scribe_session)
      @session = scribe_session
    end

    def call
      transcript = ensure_transcript!
      return @session if transcript.nil? && asr_failed?

      # Transcript outputs are a pure echo of the already-persisted transcript
      # (no LLM call), so process them FIRST — the transcript reaches :success in
      # the same instant it persists, before the slow structuring outputs run.
      # Ordering is the only behavior that changes; per-output processing,
      # isolation, and metering are unchanged. partition materializes the relation
      # once and preserves each partition's relative order, so form/note outputs
      # keep their prior order (and their stable dedupe_key) relative to one
      # another — only transcripts jump ahead.
      transcript_outputs, other_outputs =
        @session.scribe_outputs.partition { |o| o.output_type == "transcript" }

      (transcript_outputs + other_outputs).each do |output|
        # Idempotent re-commit: an already-successful output is not reprocessed
        # or re-metered, so retrying a failed/partial session only reruns the
        # outputs that still need it. ScribeOutput's status enum is PREFIXED.
        next if output.status_success?

        stage = process_output(output, transcript)
        # Metering is best-effort and runs OUTSIDE the per-output rescue so a
        # metering failure can never demote a finalized output to :failure or
        # change the session rollup. A persisted success stays a success.
        meter_output(output, stage) if stage
      end

      finalize_session_status!
      @session
    end

    private

    attr_reader :session

    # Runs ASR a single time for the session (shared by every output). Returns
    # the persisted Transcript, or nil if ASR failed (in which case the session
    # and all outputs have already been marked failed).
    #
    # When the incremental flag is ON and transcription SEGMENTS exist (plan 022
    # incremental path) the transcript is assembled from their ordered texts —
    # each segment was already transcribed + metered on arrival, so there is no
    # whole-file ASR re-download in the happy path. Otherwise (flag off — even if
    # stale segments exist from before it was flipped — or single-shot/chunked
    # storage only) the whole-file path runs and meters :asr exactly as before.
    # Gating on the flag here makes SCRIBE_INCREMENTAL_ASR=false a true kill
    # switch: every commit routes through the proven whole-file path immediately.
    def ensure_transcript!
      return session.transcript if session.transcript.present?

      if Scribe::Incremental.enabled? && session.transcript_segments.exists?
        transcript_from_segments!
      else
        transcript_from_whole_file!(meter: true)
      end
    rescue Llm::Error => e
      mark_asr_failure!(e)
      @asr_failed = true
      nil
    end

    # Runs ASR once on the whole reassembled audio blob and persists a
    # Transcript. The normal flag-off / no-segments path calls this with
    # meter: true and meters :asr exactly as before. The segment-failure safety
    # net (below) calls it with meter: false so it re-transcribes for
    # COMPLETENESS ONLY without recording a second :asr usage_event — the
    # already-metered segments are the billed quantity.
    def transcript_from_whole_file!(meter: true)
      config = Llm::ConfigResolver.call(function: :asr, account: session.account)

      asr_result = with_audio do |audio_io|
        if audio_io.nil?
          raise Llm::Error, "no audio attached to scribe session"
        end

        duration = Scribe::AudioDuration.for_blob(session.audio_files.first, file: audio_io)

        Scribe::AsrStage.new(config: config).call(
          audio_io,
          language: session.language,
          mode: config.asr_mode,
          audio_seconds: duration.seconds
        )
      end

      transcript = persist_transcript!(asr_result)
      # Metering is best-effort: a failure here must NOT fail the session once
      # the transcript has persisted successfully. `meter(function: :asr, ...)`
      # is a method call (parens) even though a boolean local `meter` shadows the
      # bareword; `if meter` reads that local. Skipped on the safety-net path so
      # the fallback never double-charges an already-metered segment set.
      meter(function: :asr, stage: asr_result) if meter
      transcript
    end

    # Builds the Transcript from the ordered segment texts, finishing any
    # trailing segment inline first (through the segment job's SAME atomic claim,
    # so an in-flight async job is never double-called). Falls back to a
    # whole-file ASR pass ONLY when a segment is still failed after the inline
    # finish (a coverage gap) — and that fallback is NOT re-metered, because each
    # done segment was already metered by its own job.
    def transcript_from_segments!
      finish_incomplete_segments!
      segments = session.transcript_segments.reload.order(:seq).to_a

      # COMPLETENESS-ONLY fallback: a still-failed segment is a gap, so
      # re-transcribe the whole file for coverage WITHOUT metering. The
      # per-segment key "<sid>:segment:<segid>:asr" and the whole-file key
      # "<sid>:asr" are DISTINCT, so the unique usage-event index would NOT
      # dedupe a second charge — the fallback must SKIP metering, accepting the
      # already-metered segments as the billed quantity (a small under-bill for
      # the failed gap).
      return transcript_from_whole_file!(meter: false) if segments.any?(&:status_failed?)

      done = segments.select(&:status_done?)
      Transcript.create!(
        scribe_session: session,
        text: done.map(&:text).reject(&:blank?).join(" "),
        language: done.map(&:language).compact.first,
        duration_seconds: done.sum { |s| s.duration_seconds.to_f },
        provider: done.first&.provider,
        model: done.first&.model
      )
    end

    # Finish every not-yet-done segment before assembly, without ever
    # double-transcribing:
    #   - transcribing: an async job already claimed it — WAIT for it to settle
    #     rather than re-invoking the provider.
    #   - pending/failed: transcribe inline via perform_now, which goes through
    #     the SAME atomic claim, so if the async job wins the race this no-ops.
    def finish_incomplete_segments!
      session.transcript_segments.where.not(status: "done").find_each do |segment|
        if segment.status_transcribing?
          wait_for_segment(segment)
        else
          TranscribeSegmentJob.perform_now(segment.id)
        end
      end
    end

    # Bounded poll: give an in-flight async TranscribeSegmentJob time to reach a
    # settled status (done/failed) before assembly. Never calls the provider.
    def wait_for_segment(segment, timeout: 15.seconds, interval: 0.5)
      deadline = Time.current + timeout
      loop do
        segment.reload
        return segment unless segment.status_transcribing?
        break if Time.current >= deadline

        sleep interval
      end
      segment
    end

    def asr_failed?
      @asr_failed
    end

    def persist_transcript!(asr_result)
      Transcript.create!(
        scribe_session: session,
        text: asr_result.text,
        language: asr_result.language,
        duration_seconds: asr_result.duration_seconds,
        provider: asr_result.provider,
        model: asr_result.model
      )
    end

    # ASR is shared: if it fails, no output can be produced. Mark the session and
    # every output failed and stop.
    def mark_asr_failure!(error)
      session.scribe_outputs.each do |output|
        output.result_errors = Array(output.result_errors) + [{ message: error.message }]
        output.update!(status: :failure)
      end
      session.update!(status: :failed, error: { message: error.message })
    end

    # Each output is isolated: a failure sets that output to :failure and pushes
    # the message into result_errors without aborting siblings.
    #
    # Returns the StructuringStage::Result for a form/note output (so the caller
    # can meter it OUTSIDE this rescue), or nil for a transcript output (no LLM
    # attempt -> nothing to meter) or any failed output. Metering deliberately
    # does NOT happen here: a post-success metering error must never demote an
    # already-persisted success to :failure.
    def process_output(output, transcript)
      case output.output_type
      when "transcript"
        process_transcript_output(output, transcript)
        nil
      when "form"
        process_form_output(output, transcript)
      when "note"
        process_note_output(output, transcript)
      else
        raise "unknown output_type=#{output.output_type.inspect}"
      end
    rescue StandardError => e
      output.result_errors = Array(output.result_errors) + [{ message: e.message }]
      output.status = :failure
      output.save!
      nil
    end

    def process_transcript_output(output, transcript)
      output.result = { text: transcript.text, language: transcript.language }
      output.status = :success
      output.save!
    end

    # Returns the StructuringStage::Result so the caller can meter it.
    def process_form_output(output, transcript)
      # An inline-fields output carries its own ad-hoc schema (no Page); fall
      # back to the page's persisted form fields + prompt otherwise.
      if output.inline_fields.present?
        fields = Scribe::InlineField.build_all(output.inline_fields)
        system_prompt = nil
      else
        fields = output.page.form_fields.to_a
        system_prompt = output.page.prompt
      end

      config = Llm::ConfigResolver.call(
        function: :structuring, page: output.page, account: session.account
      )

      stage = Scribe::StructuringStage.new(
        config: config,
        fields: fields,
        context: output.context,
        system_prompt: system_prompt
      ).call(transcript.text)

      output.result = stage.structured
      if stage.valid
        output.status = :success
      else
        output.status = :partial
        output.result_errors = stage.errors
      end
      output.save!

      stage
    end

    # Returns the StructuringStage::Result so the caller can meter it.
    def process_note_output(output, transcript)
      config = Llm::ConfigResolver.call(
        function: :structuring, page: output.page, account: session.account
      )

      system_prompt = output.template_ref.presence || output.page&.prompt

      stage = Scribe::StructuringStage.new(
        config: config,
        fields: [note_field],
        context: {},
        system_prompt: system_prompt
      ).call(transcript.text)

      structured = stage.structured || {}
      output.result = { note: structured[NOTE_KEY] }
      output.status = :success
      output.save!

      stage
    end

    def note_field
      NoteField.new(
        title: NOTE_KEY,
        friendly_name: "Clinical note",
        description: nil,
        field_type: "string",
        enum_options: nil,
        minimum: nil,
        maximum: nil
      )
    end

    # Best-effort metering for a per-output structuring attempt. A metering error
    # must never mutate the already-finalized output's status or fail the
    # session, so it is logged and swallowed.
    def meter_output(output, stage)
      meter(function: :structuring, stage: stage, scribe_output: output)
    end

    # Records + deducts a usage_event for one physical attempt, best-effort.
    # Errors are logged and swallowed: metering must never demote a finalized
    # output or fail the session. A usage_event left :pending by such a failure
    # is swept to :failed by Metering::ReservationSweeper; holds are postpaid, so
    # no credit balance is returned.
    def meter(function:, stage:, scribe_output: nil)
      record_and_deduct(function: function, stage: stage, scribe_output: scribe_output)
    rescue StandardError => e
      Rails.logger.error(
        "Scribe::Orchestrator metering failed for session=#{session.id} " \
        "function=#{function} output=#{scribe_output&.id}: #{e.class}: #{e.message}"
      )
      nil
    end

    # Records a usage_event for this physical attempt and deducts it from the
    # ledger. QuotaGuard is a no-op for accounts without an AccountCredit.
    #
    # The stage result structs (AsrStage::Result / StructuringStage::Result) do
    # NOT respond to #latency_ms, but Metering::UsageRecorder consumes the
    # Llm::Result contract (usage / provider / model / latency_ms). Wrap the
    # stage struct into an Llm::Result so the meter sees the shape it expects.
    def record_and_deduct(function:, stage:, scribe_output: nil)
      event = Metering::UsageRecorder.record(
        account: session.account,
        function: function,
        result: as_llm_result(stage),
        api_token: session.api_token,
        scribe_session: session,
        scribe_output: scribe_output,
        dedupe_key: dedupe_key_for(function, scribe_output)
      )
      Metering::QuotaGuard.deduct!(event)
      event
    end

    # Deterministic dedupe_key so the unique (api_token_id, dedupe_key) index
    # turns a retried finalize into a no-op instead of a duplicate UsageEvent.
    # A duplicate insert raises ActiveRecord::RecordNotUnique, which the
    # best-effort #meter rescue swallows without demoting the output. Format is a
    # stable contract for the index — see plan 004.
    def dedupe_key_for(function, scribe_output)
      if scribe_output
        "#{session.id}:#{scribe_output.id}:#{function}"
      else
        "#{session.id}:#{function}"
      end
    end

    # Adapts a stage result struct to the Llm::Result contract the meter reads.
    # latency_ms is not surfaced by the stage structs, so it is left nil (the
    # column is nullable); the metered usage/provider/model are preserved.
    def as_llm_result(stage)
      Llm::Result.new(
        text: stage.respond_to?(:text) ? stage.text : nil,
        structured: stage.respond_to?(:structured) ? stage.structured : nil,
        model: stage.model,
        provider: stage.provider,
        usage: stage.usage,
        latency_ms: stage.respond_to?(:latency_ms) ? stage.latency_ms : nil,
        finish_reason: stage.respond_to?(:finish_reason) ? stage.finish_reason : nil,
        raw: stage.respond_to?(:raw) ? stage.raw : nil
      )
    end

    # completed: every output succeeded.
    # failed:    every output failed.
    # partial:   a mix (or any non-success alongside a success).
    def finalize_session_status!
      statuses = session.scribe_outputs.map(&:status)
      session.update!(status: rollup_status(statuses))
    end

    def rollup_status(statuses)
      return :completed if statuses.empty?

      if statuses.all? { |s| s == "success" }
        :completed
      elsif statuses.all? { |s| s == "failure" }
        :failed
      else
        :partial
      end
    end

    # Yields a rewound Tempfile of the full session audio (ruby-openai's
    # multipart layer needs an IO with #path, not a URL) and always closes it.
    # Delegates to Scribe::AudioSource, which reads the content exactly once —
    # from the attached blob, or by assembling chunks into one tempfile it also
    # attaches — so ASR is fed without a second full-file download. Real duration
    # is measured by Scribe::AudioDuration (exact via ffprobe/blob metadata, else
    # a flagged byte-size estimate) and passed as audio_seconds so ASR is billed
    # per minute rather than metered at 0.
    def with_audio(&block)
      Scribe::AudioSource.with_audio(session, &block)
    end
  end
end
