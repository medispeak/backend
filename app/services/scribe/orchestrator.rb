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

    # The "transcript" a combined run structures from: there is none, so say so
    # rather than sending an empty string, which reads as "the document was
    # blank" to a model that is also being handed the document itself.
    COMBINED_PROMPT = "Read the attached document and fill the fields from it.".freeze

    def initialize(scribe_session)
      @session = scribe_session
    end

    def call
      return call_combined if combined_extraction?

      transcript = ensure_transcript!
      return @session if transcript.nil? && transcript_failed?

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

    # Extracts the session's source text a single time (shared by every
    # output) and persists it as the Transcript. Returns the Transcript, or nil
    # if extraction failed (session and outputs already marked failed).
    #
    # ONE transcript-source rule per modality:
    #   document: vision OCR over the uploaded document files.
    #   audio with transcription segments: assembled from those segments ONLY
    #     (each transcribed + metered on arrival).
    #   audio without segments: whole-file ASR.
    # There is no cross-source fallback — a segment set that did not fully
    # settle is an explicit failure (see transcript_from_segments!), never a
    # silently substituted whole-file transcript.
    def ensure_transcript!
      return session.transcript if session.transcript.present?

      if session.modality_document?
        transcript_from_documents!
      elsif session.transcript_segments.exists?
        transcript_from_segments!
      else
        transcript_from_whole_file!
      end
    # Llm::Error is the EXPECTED failure, but extraction does more than call a
    # provider: it downloads blobs (ActiveStorage::FileNotFoundError on a purged
    # or half-written attachment), base64-encodes them, and writes a Transcript
    # (ActiveRecord::RecordInvalid). Any of those escaping this rescue left every
    # ScribeOutput sitting at :pending, skipped the webhook, and returned a
    # :failed session whose `error` was empty — a silent wedge with no client
    # signal. Everything that can stop a transcript existing is therefore handled
    # the same way, and the unexpected classes are logged with a backtrace so a
    # real bug is still diagnosable rather than merely absorbed.
    rescue StandardError => e
      meter_failed_attempt(e)
      mark_transcript_failure!(e, client_message_for(e))
      @transcript_failed = true
      nil
    end

    # What the CLIENT is allowed to read about a failure.
    #
    # Llm::Error messages are written for this: the adapters deliberately reduce
    # provider internals to things like "provider request failed (status 502)"
    # before raising. Everything else reaching the widened rescue is an internal
    # exception whose message routinely carries SQL and column names
    # (ActiveRecord::StatementInvalid), bucket names and object keys
    # (Aws::S3::Errors), or filesystem paths (Errno::*) — and this string is
    # serialized to the public `errors` key and printed in the playground. That
    # is CWE-209, and ExceptionHandler already forbids it for controllers.
    # The real message goes to the log with a backtrace instead.
    def client_message_for(error)
      return error.message if error.is_a?(Llm::Error)

      Rails.logger.error(
        "Scribe::Orchestrator transcript extraction failed for session=#{session.id} " \
        "modality=#{session.modality}: #{error.class}: #{error.message}\n" \
        "#{Array(error.backtrace).first(10).join("\n")}"
      )
      "transcript extraction failed"
    end

    # Records provider spend on an attempt we could not use.
    #
    # A truncated extraction or an empty completion arrives as a 200: the
    # provider counted those tokens and will invoice them whether or not the
    # result was usable. Metering only the successes meant every such attempt —
    # and every retry of one — was real money absorbed silently, invisible in
    # both the admin ledger and the usage API.
    #
    # Recorded as :failed and deliberately NOT passed to QuotaGuard.deduct!: the
    # customer is not charged for a run that produced nothing (the UI promises
    # exactly that), but our own cost stops being invisible. Errors that carry
    # no usage — a timeout, a 5xx, a connection reset — are skipped, because
    # nothing was returned and nothing was billed.
    def meter_failed_attempt(error)
      # An error can carry the billed attempts Llm::Caller abandoned before it
      # (primary truncated, then the fallback failed too). Each is a physical
      # attempt of its own; recorded FIRST so it takes the lower attempt number,
      # matching the order the provider actually saw them.
      error.discarded.each { |earlier| meter_failed_attempt(earlier) } if error.respond_to?(:discarded)
      return unless error.respond_to?(:billable?) && error.billable?

      function = session.modality_document? ? :ocr : :asr
      Metering::UsageRecorder.record(
        account: session.account,
        function: function,
        result: Llm::Result.new(
          usage: usage_for_failed_attempt(error.usage, function),
          provider: error.provider, model: error.model, latency_ms: error.latency_ms
        ),
        api_token: session.api_token,
        scribe_session: session,
        status: :failed,
        # OCR keys by attempt number, so this failure occupies attempt N and a
        # retry's success takes N+1 — one row per physical attempt, which is the
        # point. Anything else gets an explicit ":failed:N" suffix so it can
        # never occupy the key a later SUCCESS needs: that collision would raise
        # RecordNotUnique inside the best-effort #meter, skip QuotaGuard.deduct!,
        # and leave a real charge unbilled and permanently marked failed. N
        # counts the failed rows already written for this function, so a second
        # billed failure (a re-commit that fails the same way) is a second row
        # rather than a swallowed RecordNotUnique.
        dedupe_key: function == :ocr ? dedupe_key_for(:ocr, nil) : failed_dedupe_key_for(function)
      )
    rescue StandardError => e
      Rails.logger.error(
        "Scribe::Orchestrator failed-attempt metering failed for session=#{session.id}: " \
        "#{e.class}: #{e.message}"
      )
      nil
    end

    # The adapter's usage knows tokens but nothing about pages — OcrStage grafts
    # the count on, and that only happens on the success path. Without this the
    # :failed event prices at Llm::Usage's default `pages: 0`, so PriceBook's
    # per-page component comes out at zero and the failed attempt records only
    # its token cost. That would hide exactly the quantity the commit hold was
    # sized on, on the one modality this metering exists for.
    def usage_for_failed_attempt(usage, function)
      return usage unless function == :ocr && usage

      Llm::Usage.new(
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        audio_seconds: usage.audio_seconds,
        pages: session.document_pages,
        estimated: usage.estimated
      )
    end

    # Runs vision OCR once over all attached documents, persists the extracted
    # text as the Transcript, and meters the attempt as function: :ocr
    # (dedupe "{session}:ocr"). Structuring then consumes the transcript text
    # exactly as it does for audio.
    # One vision call straight to the form fields, instead of OCR-then-structure.
    #
    # Cheaper because it never emits the extracted text: output tokens cost ~6x
    # input and the text is the bulk of them, so this is ~3x on a one-page
    # report. The text is exactly what it gives up, which is why every gate
    # below is about making sure nobody is relying on it.
    #
    # Fails CLOSED to the two-call path — never a 4xx. The mode is an operator's
    # server-side assignment that can change between create and commit, so
    # refusing would blame the client for a decision they did not make.
    def combined_extraction?
      return false unless session.modality_document?
      return false unless ocr_config.ocr_mode == :extract_and_structure

      reason = combined_skip_reason
      if reason
        # The operator switched this on and is not getting it. Silence here is
        # how a deliberate config comes to look broken, so say which guard
        # refused and why.
        Rails.logger.info(
          "Scribe::Orchestrator combined extraction skipped for session=#{session.id}: #{reason}"
        )
        return false
      end
      true
    rescue StandardError => e
      # Resolving config must never be what fails a session.
      Rails.logger.warn("combined extraction check failed for session=#{session.id}: #{e.class}")
      false
    end

    # nil when the session is eligible, else why it is not — in the operator's
    # terms, not the code's.
    def combined_skip_reason
      # Only ONE thing stops a configured mode now: a model that cannot return
      # schema-valid JSON would produce unusable output, so that falls back to
      # the two-call path rather than failing the run outright.
      #
      # Deliberately NOT checked any more — the operator asked for one call, so
      # they get one call:
      #   * a declared transcript output. It resolves to text: null, because
      #     that is the truth: no text was produced.
      #   * more than one structured output. Each gets its own combined call,
      #     which re-sends the document and therefore costs MORE than one
      #     extraction feeding N cheap text calls. Their trade to make.
      #   * page count. The output budget is sized per call anyway.
      unless structuring_capable?(ocr_config)
        return "#{ocr_config.api_model_id} is not marked able to return schema-valid JSON " \
               "(needs can_structure, plus supports_json_schema unless it is an Anthropic model)"
      end

      if ocr_config.fallback && !structuring_capable?(ocr_config.fallback)
        return "the fallback #{ocr_config.fallback.api_model_id} cannot return schema-valid JSON, " \
               "and it would inherit this mode"
      end

      nil
    end

    def structuring_capable?(config)
      return false unless config.capability?(:can_structure)
      return true if config.provider_kind == :anthropic

      config.capability?(:supports_json_schema)
    end

    # Runs the single output through one vision call. Mirrors #call's per-output
    # isolation, metering and rollup so nothing downstream can tell the
    # difference except that the transcript carries no text.
    # One vision call PER structured output, each reading the document directly.
    # A single-output session — the case this exists for — is therefore exactly
    # one provider call. Transcript outputs are echoes and run last, since they
    # need the stub to exist.
    def call_combined
      structured, echoes = session.scribe_outputs.partition { |o| o.output_type != "transcript" }

      structured.each do |output|
        next if output.status_success?

        stage = process_combined_output(output)
        break if stage.nil? # the run failed; do not spend another call

        meter_combined(stage)
      end

      unless transcript_failed?
        echoes.each do |output|
          next if output.status_success?

          process_transcript_output(output, session.reload.transcript)
        end
      end

      finalize_session_status!
      session
    end

    def process_combined_output(output)
      stage = combined_stage_for(output)
      # A note output keeps its own { note: ... } contract, as the split path
      # builds it — the shape is the client's, not this path's business.
      if output.output_type == NOTE_KEY
        output.result = { note: (stage.structured || {})[NOTE_KEY] }
        output.status = :success
      elsif stage.valid
        output.result = stage.structured
        output.status = :success
      else
        # :partial, not :failure, and result_errors only when there are some —
        # the column is NOT NULL. Same shape as the split path's form output, so
        # the rollup and the UI cannot tell which path produced it.
        output.result = stage.structured
        output.status = :partial
        output.result_errors = stage.errors
      end
      output.save!
      # A stub Transcript keeps `session.transcript.present?` meaning "this
      # session has been extracted", which is the re-commit short-circuit and
      # the admin/UI signal. text is nil because none was ever emitted; the UI
      # already has an honest branch for that.
      persist_stub_transcript!(stage)
      stage
    rescue Llm::Error => e
      meter_failed_attempt(e)
      mark_transcript_failure!(e, client_message_for(e))
      @transcript_failed = true
      nil
    rescue StandardError => e
      mark_transcript_failure!(e, client_message_for(e))
      @transcript_failed = true
      nil
    end

    def combined_stage_for(output)
      if output.output_type == NOTE_KEY
        fields = [ note_field ]
        system_prompt = output.template_ref.presence || output.page&.prompt
      elsif output.inline_fields.present?
        fields = Scribe::InlineField.build_all(output.inline_fields)
        system_prompt = nil
      else
        fields = output.page.form_fields.to_a
        system_prompt = output.page.prompt
      end

      Scribe::StructuringStage.new(
        config: ocr_config, fields: fields,
        context: output.context, system_prompt: system_prompt
      ).call(COMBINED_PROMPT, documents: documents!)
    end

    # Idempotent: a :partial output is retried on re-commit and lands here
    # again, and Transcript is a has_one — a second create would either violate
    # the constraint or leave two rows.
    def persist_stub_transcript!(stage)
      session.reload.transcript || Transcript.create!(
        scribe_session: session, text: nil, language: session.language,
        provider: stage.provider, model: stage.model
      )
    end

    # One UsageEvent, function :ocr — the call IS the OCR call, and keying it
    # :ocr keeps ocr_attempt_number, the per-page price component and the
    # existing ledger semantics intact. Keyed explicitly rather than through
    # dedupe_key_for's per-output branch, which carries no attempt counter.
    # Keyed with no scribe_output, so dedupe_key_for yields the per-attempt
    # "{session}:ocr:{n}" form rather than the output-keyed one, which carries
    # no attempt counter.
    def meter_combined(stage)
      meter(function: :ocr, stage: stage, usage: usage_with_pages(stage.usage))
    end

    def usage_with_pages(usage)
      return usage unless usage

      Llm::Usage.new(
        input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
        audio_seconds: usage.audio_seconds, pages: session.document_pages,
        estimated: usage.estimated
      )
    end

    # Sorted by attachment id, which is upload order, which is the order the
    # client intended the report to read in. The association carries no ORDER BY
    # of its own, so page 3 of a split report could otherwise be read ahead of
    # page 1 and the text would interleave silently.
    def documents!
      @documents ||= begin
        docs = session.document_files.attachments.sort_by(&:id).map do |file|
          {
            data: file.blob.download,
            content_type: file.blob.content_type,
            filename: file.blob.filename.to_s
          }
        end
        raise Llm::Error, "no documents attached to scribe session" if docs.empty?

        docs
      end
    end

    def ocr_config
      @ocr_config ||= Llm::ConfigResolver.call(
        function: :ocr, page: shared_page, account: session.account
      )
    end

    # The page every output shares, when they share one — so an OCR assignment
    # made at Page or Template scope is actually reachable. nil (today's
    # behaviour) when the outputs span pages and no single scope applies.
    def shared_page
      pages = session.scribe_outputs.map(&:page).uniq
      pages.size == 1 ? pages.first : nil
    end

    def transcript_from_documents!
      config = ocr_config

      documents = documents!

      stage = Scribe::OcrStage.new(config: config).call(
        documents, pages: session.document_pages
      )

      transcript = Transcript.create!(
        scribe_session: session,
        text: stage.text,
        language: session.language,
        provider: stage.provider,
        model: stage.model
      )
      # Ordered BEFORE the success so each abandoned attempt takes the lower
      # attempt number: ocr_attempt_number counts rows already written, so
      # metering the discard first yields ":ocr:0" for the attempt that failed
      # and ":ocr:1" for the one that worked, which is the real sequence.
      Array(stage.discarded_attempts).each { |e| meter_failed_attempt(e) }
      meter(function: :ocr, stage: stage)
      transcript
    end

    # Runs ASR once on the whole reassembled audio blob, persists a Transcript,
    # and meters the attempt as function: :asr.
    def transcript_from_whole_file!
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
      # the transcript has persisted successfully.
      meter(function: :asr, stage: asr_result)
      transcript
    end

    # Builds the Transcript from the ordered segment texts. Every segment was
    # transcribed + metered on arrival (or settled inline by
    # ProcessScribeSessionJob before this runs), so assembly is pure
    # concatenation and NEVER metered.
    #
    # COMPLETENESS: assembly requires every segment settled to done. Anything
    # else is an EXPLICIT failure naming the unsettled seqs — concatenating just
    # the done segments would silently drop clinical audio, and substituting a
    # whole-file re-transcription would silently replace the transcript the
    # clinician already saw live. The session finalizes :failed and a re-commit
    # retries exactly the unsettled segments (their pending/failed status makes
    # them claimable by TranscribeSegmentJob).
    def transcript_from_segments!
      segments = session.transcript_segments.order(:seq).to_a

      unless segments.all?(&:status_done?)
        unsettled = segments.reject(&:status_done?).map(&:seq).sort
        raise Llm::Error,
              "transcription incomplete for segment(s) #{unsettled.join(', ')}; re-commit to retry"
      end

      Transcript.create!(
        scribe_session: session,
        text: segments.map(&:text).reject(&:blank?).join(" "),
        language: segments.map(&:language).compact.first,
        duration_seconds: segments.sum { |s| s.duration_seconds.to_f },
        provider: segments.first&.provider,
        model: segments.first&.model
      )
    end

    def transcript_failed?
      @transcript_failed
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

    # The transcript is shared: if it cannot be produced — by ASR, by segment
    # assembly, or by document OCR — no output can be. Mark the session and every
    # output failed and stop. Named for the transcript rather than for ASR
    # because the document modality reaches it too.
    def mark_transcript_failure!(error, message = error.message)
      session.scribe_outputs.each do |output|
        output.result_errors = Array(output.result_errors) + [ { message: message } ]
        output.update!(status: :failure)
      end
      session.update!(status: :failed, error: { message: message })
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
      output.result_errors = Array(output.result_errors) + [ { message: e.message } ]
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
        fields: [ note_field ],
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
    def meter(function:, stage:, scribe_output: nil, usage: nil)
      record_and_deduct(function: function, stage: stage, scribe_output: scribe_output, usage: usage)
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
    def record_and_deduct(function:, stage:, scribe_output: nil, usage: nil)
      event = Metering::UsageRecorder.record(
        account: session.account,
        function: function,
        result: as_llm_result(stage, usage: usage),
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
    #
    # Suffixed with a per-output attempt number, same reasoning as
    # ocr_attempt_number: a transcript-edit reprocess (PATCH .../transcript)
    # resets an already-:success output back to :pending and restructures it, a
    # SECOND physical attempt at the same output. Without the suffix that second
    # attempt's insert collides with the first attempt's row on the unique
    # (api_token_id, dedupe_key) index, the best-effort #meter rescue swallows
    # it, and the reprocess is never charged.
    def dedupe_key_for(function, scribe_output)
      if scribe_output
        attempt = session.usage_events.where(scribe_output: scribe_output, function: function.to_s).count
        "#{session.id}:#{scribe_output.id}:#{function}:#{attempt}"
      elsif function == :ocr
        "#{session.id}:ocr:#{ocr_attempt_number}"
      else
        "#{session.id}:#{function}"
      end
    end

    # OCR is metered once per PHYSICAL attempt, which is the pipeline's stated
    # metering contract (see this class's header). A re-commit of a failed
    # document session finds no transcript, runs OCR again, and is charged again
    # by the provider — but a key of "{session}:ocr" collided with the first
    # attempt's row on the unique (api_token_id, dedupe_key) index, and the
    # RecordNotUnique was swallowed by the best-effort #meter. Every retry after
    # the first was therefore real provider spend billed to nobody.
    #
    # Counting prior attempts is safe rather than racy: commit's atomic claim
    # (only one request may move a session to :processing) makes the orchestrator
    # single-flight per session. A job retry that re-runs a SETTLED attempt still
    # short-circuits earlier, at `session.transcript.present?`, so it never
    # reaches here and cannot double-bill.
    def ocr_attempt_number
      session.usage_events.where(function: "ocr").count
    end

    # Key for a billed-but-unusable attempt of a function that is not metered
    # per attempt (ASR today). Suffixed with the number of failed rows already
    # written for that function so repeated failures each get their own row.
    def failed_dedupe_key_for(function)
      failed = session.usage_events.where(function: function.to_s, status: "failed").count
      "#{session.id}:#{function}:failed:#{failed}"
    end

    # Adapts a stage result struct to the Llm::Result contract the meter reads.
    # The stage structs carry latency_ms (ASR/OCR from the adapter, structuring
    # timed across the whole stage so a repair re-ask is counted), so it reaches
    # usage_events; the respond_to? guard remains for any struct that does not.
    # `usage` overrides the stage's own — a combined run grafts the page count
    # on, which only OcrStage does for itself.
    def as_llm_result(stage, usage: nil)
      Llm::Result.new(
        text: stage.respond_to?(:text) ? stage.text : nil,
        structured: stage.respond_to?(:structured) ? stage.structured : nil,
        model: stage.model,
        provider: stage.provider,
        usage: usage || stage.usage,
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
