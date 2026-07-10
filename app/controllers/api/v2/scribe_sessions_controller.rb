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

        upload = params[:audio]
        if upload.blank?
          render_error(code: "validation_error", message: "audio file is required", status: :unprocessable_entity)
          return
        end
        unless ScribeSession::ALLOWED_AUDIO_TYPES.include?(upload.content_type)
          render_error(
            code: "validation_error",
            message: "unsupported audio content type: #{upload.content_type}",
            status: :unprocessable_entity
          )
          return
        end
        if upload.size > ScribeSession::MAX_AUDIO_BYTES
          render_error(
            code: "audio_upload_failed",
            message: "audio exceeds #{ScribeSession::MAX_AUDIO_BYTES} bytes",
            status: :unprocessable_entity
          )
          return
        end

        session.audio_files.attach(upload)
        session.update!(status: "uploading")

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
        if upload.respond_to?(:size) && upload.size > MAX_CHUNK_BYTES
          render_error(code: "validation_error", message: "chunk too large", status: :unprocessable_entity)
          return
        end

        chunk = session.audio_chunks.find_or_initialize_by(seq: seq)
        chunk.content_type = upload.content_type.presence || chunk.content_type || "audio/webm"
        chunk.final = true if ActiveModel::Type::Boolean.new.cast(params[:final])
        chunk.data.attach(upload)
        chunk.save!
        session.update!(status: "uploading") if session.created?

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

      # POST /api/v2/scribe_sessions/:id/commit
      def commit
        session = find_session
        return unless session
        return if reject_expired(session)

        # Idempotency guard: only commit from a committable status. created and
        # uploading are first commits; failed and partial re-commit to retry the
        # not-yet-successful outputs (Orchestrator skips already-successful ones).
        # processing (in flight) and completed (done) are rejected so a duplicate
        # POST never re-runs the pipeline and double-charges. ScribeSession's
        # status enum is UNPREFIXED, so the predicates are bare (session.created?).
        unless session.created? || session.uploading? || session.failed? || session.partial?
          render_error(
            code: "validation_error",
            message: "Session cannot be committed from status #{session.status}",
            status: :conflict
          )
          return
        end

        # Browser clients upload via chunked parts; stitch them into the session's
        # canonical audio blob so the Orchestrator path below runs unchanged. This
        # sits BEFORE the quota hold (plan 002) and OUTSIDE with_idempotency so a
        # no-audio commit is a plain, retryable 422 and never a cached response.
        # The audio_files.blank? guard makes it a no-op once a blob exists (a
        # single-shot upload or a prior reassembly), so a retried commit is safe.
        if session.audio_files.blank? && session.audio_chunks.exists?
          Scribe::ChunkAssembler.assemble!(session)
        end
        if session.audio_files.blank?
          render_error(
            code: "audio_upload_failed",
            message: "No audio uploaded for this session",
            status: :unprocessable_entity
          )
          return
        end

        fingerprint = "commit:#{session.id}"
        with_idempotency(fingerprint) do
          # Meter against the session's own account. For an account-token request
          # this is current_account (the session is account-scoped); for a scoped
          # session token current_account is nil, so sourcing it from the session
          # keeps the quota hold correct without widening the token's reach.
          token = Metering::QuotaGuard.hold!(account: session.account, estimate: commit_estimate(session))
          unless token.ok?
            # insufficient_credit is a stable, public v2 error code (402 Payment
            # Required). Accounts with no AccountCredit row are unlimited, so
            # hold! returns an ok token for them and commit proceeds.
            render_error(
              code: "insufficient_credit",
              message: "Account has insufficient credit to process this session",
              status: :payment_required
            )
            next
          end

          session.update!(status: "processing")
          ProcessScribeSessionJob.perform_later(session.id)

          render json: serialize(session), status: :accepted
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
                   .includes(:scribe_outputs)
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

      # A conservative, non-zero credit estimate for the commit hold, sized from
      # the real audio duration (plan 001's Scribe::AudioDuration). Final cost is
      # settled at deduct!; this only needs to be positive and roughly
      # proportional to the audio length so a broke account is hard-blocked.
      def commit_estimate(session)
        blob = session.audio_files.first
        seconds = blob ? Scribe::AudioDuration.for_blob(blob).seconds.to_f : 0.0
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
              unless Page.exists?(id: page_id)
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
