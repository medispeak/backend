require "digest"

module Api
  module V2
    class ScribeSessionsController < BaseController
      OUTPUT_TYPES = %w[transcript form note].freeze
      DEFAULT_PAGE_LIMIT = 50
      MAX_PAGE_LIMIT = 100
      # Per-part ceiling for a chunked upload. Deliberately well under the whole-
      # session MAX_AUDIO_BYTES: a browser streams many small parts, and a single
      # oversized part is a client bug, not a legitimate upload.
      MAX_CHUNK_BYTES = 8.megabytes
      # Minimum credit an account must hold to open a realtime session (a rough
      # floor for a ~10-min operator-billed OpenAI realtime session; realtime is
      # not per-session metered). Accounts with no AccountCredit row are unlimited.
      REALTIME_MIN_CREDIT = 0.10

      # Account-wide surfaces stay account-token only; a scoped session token can
      # never mint tokens, create sessions, or list the account's sessions.
      # show/audio/commit accept either credential via find_session.
      before_action :require_account_token!, only: [ :create, :index, :tokens ]

      # POST /api/v2/scribe_sessions
      def create
        fingerprint = Digest::SHA256.hexdigest(raw_request_body)

        with_idempotency(fingerprint) do
          outputs = Array(create_params[:outputs])

          error = validate_outputs(outputs)
          if error
            render_error(code: "validation_error", message: error, status: :unprocessable_entity)
            next
          end

          session = build_session
          unless session.valid?
            render_error(
              code: "validation_error",
              message: session.errors.full_messages.to_sentence,
              status: :unprocessable_entity
            )
            next
          end
          session.save!
          build_outputs(session, outputs)

          render json: serialize(session), status: :created
        end
      end

      # POST /api/v2/scribe_sessions/:id/audio
      def audio
        session = find_session
        return unless session
        return if reject_expired(session)

        # Only accept audio while the session is still open for upload. Without
        # this, a POST /audio after commit resets status to "uploading" (below),
        # reopening the commit gate mid-pipeline and un-terminating a completed
        # session. Mirrors the chunk/segment upload states.
        unless session.created? || session.uploading?
          render_error(
            code: "validation_error",
            message: "audio cannot be uploaded from status #{session.status}",
            status: :conflict
          )
          return
        end

        upload = params[:audio]
        if upload.blank?
          render_error(code: "validation_error", message: "audio file is required", status: :unprocessable_entity)
          return
        end
        content_type = base_audio_type(upload.content_type)
        unless ScribeSession::ALLOWED_AUDIO_TYPES.include?(content_type)
          render_error(
            code: "validation_error",
            message: "unsupported audio content type: #{upload.content_type}",
            status: :unprocessable_entity
          )
          return
        end
        # Cap the running total across ALL attachments, not just this part:
        # repeated single-shot POSTs otherwise accumulate past the 25MB ceiling
        # (the chunk path already enforces a running total). Single-shot is
        # one-file, so existing bytes are normally 0 — this bounds a misbehaving
        # client that re-POSTs.
        existing_bytes = session.audio_files.sum { |f| f.blob&.byte_size.to_i }
        if existing_bytes + upload.size.to_i > ScribeSession::MAX_AUDIO_BYTES
          render_error(
            code: "audio_upload_failed",
            message: "total audio exceeds #{ScribeSession::MAX_AUDIO_BYTES} bytes",
            status: :unprocessable_entity
          )
          return
        end

        # Attach with the normalized (parameter-stripped) content-type so the
        # blob passes the model's audio-type validation and ASR sees a clean type.
        session.audio_files.attach(
          io: upload.tempfile.tap(&:rewind),
          filename: upload.original_filename,
          content_type: content_type
        )
        session.update!(status: "uploading") if session.created?

        render json: { id: session.id, status: session.status }, status: :ok
      end

      # POST /api/v2/scribe_sessions/:id/audio/chunks
      #
      # Accepts one part of a native chunked/resumable upload: a `seq` (ordering
      # index) and a `chunk` file part. Re-POSTing a seq overwrites the stored
      # bytes (idempotent resume), so a dropped/retried part never duplicates a
      # row. Parts are stitched into the session's canonical audio blob at commit.
      def audio_chunks
        session = find_session
        return unless session
        return if reject_expired(session)

        seq = params.require(:seq).to_i
        upload = params.require(:chunk)

        # Ingress guards mirror the single-shot `audio` action so a bad part is a
        # clean 422 here, never a 500 at commit-time reassembly. seq is a
        # non-negative ordering index; the content-type must be an allowed audio
        # type; and the running total across parts must stay under the session
        # ceiling (the chunked path must not bypass plan-014's 25MB cap).
        if seq.negative?
          render_error(code: "validation_error", message: "seq must be >= 0", status: :unprocessable_entity)
          return
        end
        if upload.respond_to?(:size) && upload.size > MAX_CHUNK_BYTES
          render_error(code: "validation_error", message: "chunk too large", status: :unprocessable_entity)
          return
        end
        content_type = base_audio_type(upload.content_type).presence || "audio/webm"
        unless ScribeSession::ALLOWED_AUDIO_TYPES.include?(content_type)
          render_error(code: "validation_error", message: "unsupported audio content type: #{upload.content_type}", status: :unprocessable_entity)
          return
        end
        other_bytes = session.audio_chunks.where.not(seq: seq)
                             .with_attached_data.sum { |c| c.data.blob&.byte_size.to_i }
        if other_bytes + upload.size.to_i > ScribeSession::MAX_AUDIO_BYTES
          render_error(code: "audio_upload_failed", message: "total audio exceeds #{ScribeSession::MAX_AUDIO_BYTES} bytes", status: :unprocessable_entity)
          return
        end

        chunk = session.audio_chunks.find_or_initialize_by(seq: seq)
        chunk.content_type = content_type
        chunk.final = true if ActiveModel::Type::Boolean.new.cast(params[:final])
        chunk.data.attach(upload)
        chunk.save!
        session.update!(status: "uploading") if session.created?

        render json: { received: seq }, status: :ok
      rescue ActiveRecord::RecordNotUnique
        # A concurrent upload of the same seq already stored this part. Per-seq
        # upload is idempotent, so treat the race as success.
        render json: { received: seq }, status: :ok
      end

      # GET /api/v2/scribe_sessions/:id/audio/status
      #
      # Lets a resuming client learn which parts the server already holds so it
      # only re-sends the gaps.
      def audio_status
        session = find_session
        return unless session

        chunks = session.audio_chunks.order(:seq).to_a
        render json: {
          received_seqs: chunks.map(&:seq),
          final_seen: chunks.any?(&:final),
          bytes: chunks.sum { |c| c.data.blob&.byte_size.to_i }
        }, status: :ok
      end

      # GET /api/v2/scribe_sessions/:id/live_form
      #
      # Structures the growing LIVE transcript for this session's form outputs so
      # a client can pre-fill the form DURING recording, before commit. Returns
      # { structured_data: { key => value } } merged across every form output.
      #
      # Gated behind the live-form flag: when OFF this returns an empty object
      # (200) rather than 404, so a polling client degrades to "no pre-fill"
      # instead of erroring. The authoritative, metered fill still happens once
      # at commit (Scribe::Orchestrator); these interim passes are NOT persisted
      # or metered, so a broke account is credit-gated here to bound the extra
      # (operator-billed) LLM cost a poller could run up.
      def live_form
        session = find_session
        return unless session
        return if reject_expired(session)

        structured =
          if Scribe::Incremental.live_form_enabled? && Metering::QuotaGuard.affordable?(account: session.account)
            Scribe::LiveStructurer.new(session).call(session.live_transcript)
          else
            {}
          end

        render json: { structured_data: structured }, status: :ok
      end

      # POST /api/v2/scribe_sessions/:id/realtime_token
      #
      # Mints a short-lived ephemeral token the BROWSER uses to connect directly
      # to the realtime provider (OpenAI) for live transcription — the account
      # key never reaches the client. Realtime is a live overlay; the
      # authoritative transcript still comes from the commit pipeline. Gated
      # behind SCRIBE_REALTIME: when OFF the surface does not exist (404).
      def realtime_token
        unless Scribe::Realtime.enabled?
          render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found)
          return
        end

        session = find_session
        return unless session
        return if reject_expired(session)

        # Each mint opens a ~10-min OpenAI realtime session billed to the
        # operator's key with no per-session metering (the browser streams
        # directly). Hard-block accounts with no credit so a session token can't
        # turn realtime minting into an unbounded cost channel.
        unless Metering::QuotaGuard.affordable?(account: session.account, estimate: REALTIME_MIN_CREDIT)
          render_error(
            code: "insufficient_credit",
            message: "Account has insufficient credit for realtime transcription",
            status: :payment_required
          )
          return
        end

        result = Scribe::RealtimeToken.call(session)
        render json: {
          provider: result.provider,
          token: result.token,
          expires_at: result.expires_at,
          url: result.url,
          model: result.model,
          session: result.session
        }, status: :created
      rescue Llm::Error => e
        render_error(code: "realtime_unavailable", message: e.message, status: :unprocessable_entity)
      end

      # POST /api/v2/scribe_sessions/:id/audio/segments
      #
      # Accepts one STANDALONE, independently-decodable transcription segment: a
      # `seq` and a `segment` file part. Each segment is transcribed on arrival by
      # TranscribeSegmentJob through the same provider ASR seam, and the final
      # transcript is assembled from the ordered segment texts at commit. This is
      # a SEPARATE stream from the storage `audio/chunks` upload and is NOT
      # counted against the 25MB storage cap — dual-upload doubles audio bytes by
      # design. Re-POSTing a seq is idempotent. Gated behind the incremental
      # feature flag: when OFF the surface simply does not exist (404).
      def audio_segments
        unless Scribe::Incremental.enabled?
          render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found)
          return
        end

        session = find_session
        return unless session
        return if reject_expired(session)

        seq = params.require(:seq).to_i
        upload = params.require(:segment)

        # Ingress guards mirror the storage `audio/chunks` action so a bad part is
        # a clean 422 here, never a 500 in the segment job. seq is a non-negative
        # ordering index; the content-type must be an allowed audio type; and the
        # running total across the OTHER segments must stay under the per-session
        # segment ceiling (reusing MAX_AUDIO_BYTES — segments are NOT counted
        # against the storage cap).
        if seq.negative?
          render_error(code: "validation_error", message: "seq must be >= 0", status: :unprocessable_entity)
          return
        end
        if upload.respond_to?(:size) && upload.size > MAX_CHUNK_BYTES
          render_error(code: "validation_error", message: "segment too large", status: :unprocessable_entity)
          return
        end
        content_type = base_audio_type(upload.content_type).presence || "audio/webm"
        unless ScribeSession::ALLOWED_AUDIO_TYPES.include?(content_type)
          render_error(code: "validation_error", message: "unsupported audio content type: #{upload.content_type}", status: :unprocessable_entity)
          return
        end
        other_bytes = session.transcript_segments.where.not(seq: seq)
                             .with_attached_data.sum { |s| s.data.blob&.byte_size.to_i }
        if other_bytes + upload.size.to_i > ScribeSession::MAX_AUDIO_BYTES
          render_error(code: "audio_upload_failed", message: "total segment audio exceeds #{ScribeSession::MAX_AUDIO_BYTES} bytes", status: :unprocessable_entity)
          return
        end

        segment = session.transcript_segments.find_or_initialize_by(seq: seq)
        segment.content_type = content_type
        segment.data.attach(upload)
        segment.save!
        session.update!(status: "uploading") if session.created?

        # Transcribe on arrival through the provider seam. The job's atomic claim
        # makes a re-POST of an already-done seq a no-op, so this never
        # re-transcribes.
        TranscribeSegmentJob.perform_later(segment.id)

        render json: { received: seq }, status: :ok
      rescue ActiveRecord::RecordNotUnique
        # A concurrent upload of the same seq already stored this part. Per-seq
        # upload is idempotent, so treat the race as success.
        render json: { received: seq }, status: :ok
      end

      # POST /api/v2/scribe_sessions/:id/commit
      def commit
        session = find_session
        return unless session
        return if reject_expired(session)

        # A committable session must have SOME audio: either a single-shot blob or at
        # least one uploaded chunk. Chunk reassembly is deferred to the processing job
        # (Scribe::AudioSource) so the audio content is read exactly once on the way to
        # ASR — the job assembles and transcribes from a single tempfile rather than
        # assembling here and re-downloading the blob for ASR. This guard sits BEFORE the
        # atomic claim and OUTSIDE with_idempotency so a no-audio commit is a plain,
        # retryable 422 and never a cached response.
        if session.audio_files.blank? && !session.audio_chunks.exists?
          render_error(
            code: "audio_upload_failed",
            message: "No audio uploaded for this session",
            status: :unprocessable_entity
          )
          return
        end

        fingerprint = "commit:#{session.id}"
        with_idempotency(fingerprint) do
          # ATOMICALLY claim the commit. A check-then-act status guard let two
          # racing commits (a session token carries no Idempotency-Key, so
          # with_idempotency is a no-op there) both pass and both enqueue the
          # pipeline — double processing + duplicate Transcript rows. A single
          # conditional UPDATE lets exactly ONE request transition a committable
          # session to processing; the losers see zero rows and 409. created and
          # uploading are first commits; failed and partial re-commit to retry
          # the not-yet-successful outputs (Orchestrator skips successful ones).
          original_status = session.status
          claimed = ScribeSession
                    .where(id: session.id, status: %w[created uploading failed partial])
                    .update_all(status: "processing", updated_at: Time.current)
          if claimed.zero?
            render_error(
              code: "validation_error",
              message: "Session cannot be committed from status #{session.reload.status}",
              status: :conflict
            )
            next
          end

          # From here we hold the claim (status is processing, unclaimable by any
          # other commit). ANYTHING that fails now — the quota hold raising on a
          # lock-wait timeout/deadlock under concurrent commits, or the enqueue
          # failing — must roll the claim back, or the session is wedged in
          # processing and every future commit 409s forever. Revert then re-raise
          # (the global handler renders a sanitized 500; the session is
          # re-committable).
          begin
            # Meter against the session's own account. For a scoped session token
            # current_account is nil, so sourcing it from the session keeps the
            # quota hold correct without widening the token's reach.
            token = Metering::QuotaGuard.hold!(account: session.account, estimate: commit_estimate(session))
            unless token.ok?
              revert_commit_claim(session, original_status)
              render_error(
                code: "insufficient_credit",
                message: "Account has insufficient credit to process this session",
                status: :payment_required
              )
              next
            end

            ProcessScribeSessionJob.perform_later(session.id)
          rescue StandardError
            revert_commit_claim(session, original_status)
            raise
          end

          render json: serialize(session.reload), status: :accepted
        end
      end

      # POST /api/v2/scribe_sessions/:id/tokens  (account token only)
      #
      # Mints a short-lived, session-scoped token a browser client uses to drive
      # this one session's upload/read routes without the account secret.
      def tokens
        session = ScribeSession.where(account: current_account).find_by(id: params[:id])
        unless session
          render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found)
          return
        end

        token, exp = Scribe::SessionToken.mint(session)
        render json: { token: token, expires_at: exp.iso8601 }, status: :created
      end

      # GET /api/v2/scribe_sessions/:id
      def show
        session = find_session
        return unless session

        render json: serialize(session), status: status_for(session)
      end

      # GET /api/v2/scribe_sessions
      def index
        sessions = account_sessions
                   .includes(:scribe_outputs, :transcript, :transcript_segments, :usage_events)
                   .order(created_at: :desc)
                   .limit(page_limit)
                   .offset(page_offset)
        render json: { scribe_sessions: sessions.map { |s| serialize(s) } }, status: :ok
      end

      # Per-minute rate used only to size the pre-flight commit hold. Deliberately
      # coarse and above real provider cost (whisper ASR + gpt-4o-mini
      # structuring) so the guard is conservative; the true charge is settled by
      # QuotaGuard.deduct! after the pipeline runs. See plan 002.
      COMMIT_ESTIMATE_RATE_PER_MINUTE = 0.02
      # Floor so the estimate is always positive: any account with a zero or
      # negative balance is rejected even when the measured duration rounds to ~0.
      COMMIT_ESTIMATE_MIN_MINUTES = 1.0

      private

      # Undo a won commit claim (processing -> its prior committable status).
      # update_all bypasses dirty-tracking so the revert always writes, even when
      # the in-memory record still reads the original status.
      def revert_commit_claim(session, original_status)
        ScribeSession.where(id: session.id).update_all(status: original_status, updated_at: Time.current)
      end

      # A conservative, non-zero credit estimate for the commit hold, sized from
      # the real audio duration (plan 001's Scribe::AudioDuration). Final cost is
      # settled at deduct!; this only needs to be positive and roughly
      # proportional to the audio length so a broke account is hard-blocked.
      def commit_estimate(session)
        blob = session.audio_files.first
        seconds =
          if blob
            Scribe::AudioDuration.for_blob(blob).seconds.to_f
          else
            chunk_bytes = session.audio_chunks.with_attached_data
                                 .sum { |c| c.data.blob&.byte_size.to_i }
            chunk_bytes / Scribe::AudioDuration::ESTIMATE_BYTES_PER_SECOND
          end
        minutes = [ seconds / 60.0, COMMIT_ESTIMATE_MIN_MINUTES ].max
        (minutes * COMMIT_ESTIMATE_RATE_PER_MINUTE).round(6)
      end

      # Account-scoped session relation. Scopes through belongs_to :account
      # rather than a has_many on Account so this chunk does not depend on a
      # model it cannot edit; a cross-account :id therefore 404s.
      def account_sessions
        ScribeSession.where(account: current_account)
      end

      # Requested page size, clamped to [1, MAX_PAGE_LIMIT]; defaults to
      # DEFAULT_PAGE_LIMIT when absent or non-positive.
      def page_limit
        requested = params[:limit].presence&.to_i
        return DEFAULT_PAGE_LIMIT unless requested&.positive?

        [ requested, MAX_PAGE_LIMIT ].min
      end

      # Requested offset, floored at 0.
      def page_offset
        offset = params[:offset].presence&.to_i
        offset&.positive? ? offset : 0
      end

      # Resolves the target session for show/audio/commit under either credential.
      # An account token scopes to the account (a foreign :id 404s, unchanged); a
      # session token can only ever reach the single session its `sid` names.
      def find_session
        session =
          if current_api_token
            account_sessions.find_by(id: params[:id])
          elsif current_session_claims && current_session_claims["sid"].to_s == params[:id].to_s
            ScribeSession.find_by(id: current_session_claims["sid"])
          end
        unless session
          render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found)
          return nil
        end
        session
      end

      # Renders the shared 410 session_expired envelope and returns true when the
      # session has passed its expiry, so callers can guard with
      # `return if reject_expired(session)`. Extracted from the guard originally
      # inlined in audio/commit and now shared with audio_chunks.
      def reject_expired(session)
        return false unless session.expired?

        render_error(code: "session_expired", message: "Scribe session has expired", status: :gone)
        true
      end

      # Browser MediaRecorder sends content-types like "audio/webm;codecs=opus".
      # Compare (and store) the base MIME type, stripped of any parameters, so it
      # matches ScribeSession::ALLOWED_AUDIO_TYPES.
      def base_audio_type(content_type)
        content_type.to_s.split(";").first.to_s.strip.downcase
      end

      def build_session
        ScribeSession.new(
          account: current_account,
          api_token: current_api_token,
          user: current_api_token.user,
          status: "created",
          language: create_params[:language_hint],
          mode: create_params[:mode].presence || "consultation",
          callback_url: create_params[:callback_url],
          idempotency_key: idempotency_key_header,
          expires_at: 24.hours.from_now
        )
      end

      def build_outputs(session, outputs)
        outputs.each do |output|
          output = output.to_h.with_indifferent_access
          session.scribe_outputs.create!(
            status: "pending",
            output_type: output[:type],
            page_id: output[:page_id],
            template_ref: output[:template_ref],
            context: output[:context].presence || {},
            inline_fields: output[:fields].present? ? output[:fields].map { |f| f.to_h } : nil
          )
        end
      end

      # Returns an error message string, or nil when all outputs are valid.
      def validate_outputs(outputs)
        return "outputs must be a non-empty array" if outputs.blank?

        outputs.each do |output|
          output = output.to_h.with_indifferent_access
          type = output[:type]

          unless OUTPUT_TYPES.include?(type)
            return "Invalid output type: #{type.inspect}"
          end

          if type == "form"
            # A form output carries EXACTLY one schema source: a persisted
            # page_id OR an inline `fields` array. Neither/both is a 422.
            page_id = output[:page_id]
            fields = output[:fields]
            has_page = page_id.present?
            has_fields = fields.present?
            return "form output needs exactly one of page_id or fields" if has_page == has_fields

            if has_page
              # Scope to pages the CALLER may use: its own account's templates or
              # legacy shared templates (account_id NULL, plan 013). Without this
              # scope a tenant could name another account's page_id and have the
              # pipeline read their form schema, prompt, and model assignment.
              # Same message for foreign vs absent pages so it isn't an existence
              # oracle.
              usable = Page.joins(:template)
                           .where(id: page_id)
                           .where(templates: { account_id: [ nil, current_account&.id ] })
                           .exists?
              unless usable
                return "page_id #{page_id.inspect} does not reference an existing page"
              end
            else
              err = Scribe::InlineField.validation_error(fields.map { |f| f.to_h })
              return err if err
            end
          end
        end

        nil
      end

      # 200 when terminal (completed/failed), 206 when partial, 202 otherwise.
      def status_for(session)
        case session.status
        when "completed", "failed" then :ok
        when "partial" then :partial_content
        else :accepted
        end
      end

      def serialize(session)
        ScribeSessionSerializer.new(session).as_json
      end

      # Raw request body for the idempotency fingerprint. Rewind first because
      # JSON param parsing may have already consumed the stream.
      def raw_request_body
        request.body.rewind if request.body.respond_to?(:rewind)
        body = request.body.read
        request.body.rewind if request.body.respond_to?(:rewind)
        body.to_s
      end

      def create_params
        params.permit(
          :language_hint, :mode, :callback_url,
          outputs: [
            :type, :page_id, :template_ref, { context: {} },
            { fields: [ :key, :label, :type, :description, :minimum, :maximum, { enum: [] } ] }
          ]
        )
      end
    end
  end
end
