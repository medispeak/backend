require "digest"

module Api
  module V2
    class ScribeSessionsController < BaseController
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
          result = Scribe::SessionBuilder.new(
            account: current_account,
            api_token: current_api_token,
            user: current_api_token.user,
            outputs: create_params[:outputs],
            mode: create_params[:mode],
            modality: create_params[:modality],
            language_hint: create_params[:language_hint],
            callback_url: create_params[:callback_url],
            idempotency_key: idempotency_key_header
          ).call

          unless result.success?
            render_error(
              code: result.error[:code],
              message: result.error[:message],
              status: :unprocessable_entity
            )
            next
          end

          render json: serialize(result.session), status: :created
        end
      end

      # POST /api/v2/scribe_sessions/:id/audio
      def audio
        session = find_session
        return unless session
        return if reject_expired(session)
        return if reject_wrong_modality(session, "audio")

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
        return if reject_wrong_modality(session, "audio")

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
        other_bytes = attached_bytes(session.audio_chunks.where.not(seq: seq))
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

      # POST /api/v2/scribe_sessions/:id/audio/segments
      #
      # Accepts one STANDALONE, independently-decodable transcription segment: a
      # `seq` and a `segment` file part. Each segment is transcribed on arrival by
      # TranscribeSegmentJob through the same provider ASR seam, and the final
      # transcript is assembled from the ordered segment texts at commit. This is
      # a SEPARATE stream from the storage `audio/chunks` upload and is NOT
      # counted against the 25MB storage cap. Re-POSTing a seq is idempotent.
      def audio_segments
        session = find_session
        return unless session
        return if reject_expired(session)
        return if reject_wrong_modality(session, "audio")

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
        other_bytes = attached_bytes(session.transcript_segments.where.not(seq: seq))
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

      # POST /api/v2/scribe_sessions/:id/documents
      #
      # Uploads one lab-report document (PDF or image) to a document-modality
      # session. Pages are counted here at upload time (pdf-reader; an image is
      # one page) so a bad or oversized document is a clean 4xx now, never a
      # 500 at commit, and the running document_pages total backs both the page
      # cap and per-page metering.
      def documents
        session = find_session
        return unless session
        return if reject_expired(session)
        return if reject_wrong_modality(session, "document")

        unless session.created? || session.uploading?
          render_error(
            code: "validation_error",
            message: "documents cannot be uploaded from status #{session.status}",
            status: :conflict
          )
          return
        end

        upload = params[:document]
        if upload.blank?
          render_error(code: "validation_error", message: "document file is required", status: :unprocessable_entity)
          return
        end
        content_type = base_audio_type(upload.content_type)
        unless ScribeSession::ALLOWED_DOCUMENT_TYPES.include?(content_type)
          render_error(
            code: "validation_error",
            message: "unsupported document content type: #{upload.content_type}",
            status: :unprocessable_entity
          )
          return
        end
        if upload.size.to_i > ScribeSession::MAX_DOCUMENT_FILE_BYTES
          render_error(code: "validation_error", message: "document too large", status: :unprocessable_entity)
          return
        end
        pages = count_pages(upload, content_type)
        if pages.nil?
          render_error(
            code: "validation_error",
            message: "document could not be read (encrypted or malformed PDF?)",
            status: :unprocessable_entity
          )
          return
        end

        # Both cumulative ceilings are read-check-write against state this
        # request is about to change, and a session token lets one client fire
        # its uploads concurrently. Unlocked, two requests both read
        # document_pages = 18, both see 18 + 2 <= 20, and the session lands at 22
        # — over the cap that sizes the OCR request and the credit hold. Hold the
        # session row for the whole check-attach-increment so the second request
        # reads the first one's result. `with_lock` reloads inside the
        # transaction, so the counts below are the locked row's, not the stale
        # ones this action was dispatched with.
        rejection = nil
        too_late = false
        session.with_lock do
          # The status guard above is only a fast path: counting pages can take
          # up to PDF_PARSE_TIMEOUT_SECONDS, and a commit racing that window
          # moves the session to :processing and sizes its credit hold on the
          # pages banked so far. Attaching after that point adds a page the hold
          # never covered and the OCR call may never see. Re-assert under the
          # lock, where the claim is serialized against commit's own UPDATE.
          if !session.created? && !session.uploading?
            too_late = true
          elsif session.document_files.sum { |f| f.blob&.byte_size.to_i } + upload.size.to_i >
                ScribeSession::MAX_DOCUMENT_BYTES
            rejection = "total documents exceed #{ScribeSession::MAX_DOCUMENT_BYTES} bytes"
          elsif session.document_pages + pages > ScribeSession::MAX_DOCUMENT_PAGES
            rejection = "total pages exceed #{ScribeSession::MAX_DOCUMENT_PAGES}"
          else
            session.document_files.attach(
              io: upload.tempfile.tap(&:rewind),
              filename: upload.original_filename,
              content_type: content_type
            )
            session.document_pages += pages
            session.status = "uploading" if session.created?
            session.save!
          end
        end

        if too_late
          render_error(
            code: "validation_error",
            message: "documents cannot be uploaded from status #{session.status}",
            status: :conflict
          )
          return
        end
        if rejection
          render_error(code: "document_upload_failed", message: rejection, status: :unprocessable_entity)
          return
        end

        render json: { id: session.id, status: session.status, pages: session.document_pages }, status: :ok
      end

      # POST /api/v2/scribe_sessions/:id/commit
      def commit
        session = find_session
        return unless session
        return if reject_expired(session)

        # A committable session must have SOME source content, by modality:
        # audio -> a single-shot blob, at least one uploaded chunk, or at least
        # one transcription segment (a segments-only client needs no parallel
        # storage stream); document -> at least one uploaded document. This
        # guard sits BEFORE the atomic claim and OUTSIDE with_idempotency so an
        # empty commit is a plain, retryable 422 and never a cached response.
        if session.modality_document?
          unless session.document_files.attached?
            render_error(
              code: "document_upload_failed",
              message: "No documents uploaded for this session",
              status: :unprocessable_entity
            )
            return
          end
        elsif session.audio_files.blank? && !session.audio_chunks.exists? && !session.transcript_segments.exists?
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
            estimate = commit_estimate(session)

            # Usage-limit admission gate (per-user daily caps, org budgets, ...)
            # — distinct from the credit ledger below so clients can message
            # "limit reached" differently from "out of credit".
            limit_check = Metering::LimitGuard.check(
              account: session.account,
              user: session.user,
              estimated_cost: estimate
            )
            unless limit_check.ok?
              revert_commit_claim(session, original_status)
              violation = limit_check.violation.limit
              render_error(
                code: "usage_limit_exceeded",
                message: "#{violation.period.capitalize} #{violation.metric} limit reached for this #{violation.scope == 'per_user' ? 'user' : 'account'}",
                status: :payment_required
              )
              next
            end

            # Meter against the session's own account. For a scoped session token
            # current_account is nil, so sourcing it from the session keeps the
            # quota hold correct without widening the token's reach.
            token = Metering::QuotaGuard.hold!(account: session.account, estimate: estimate)
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
      # Coarse per-page rate for the document commit hold (vision OCR +
      # structuring); same conservative-estimate philosophy as the audio rate.
      COMMIT_ESTIMATE_RATE_PER_PAGE = 0.01

      private

      # Total stored bytes across a relation of records with a `data`
      # attachment, summed in SQL.
      #
      # The running-total caps run on EVERY upload, so this must not grow with
      # the length of the consultation. The obvious
      # `relation.with_attached_data.sum { |r| r.data.blob&.byte_size.to_i }`
      # does: it materialises every sibling record, its attachment and its blob
      # just to add up one integer column, so the 300th segment of a long
      # consultation dragged back ~900 rows before it could be accepted.
      def attached_bytes(relation)
        ActiveStorage::Blob
          .joins(:attachments)
          .where(active_storage_attachments: {
            record_type: relation.klass.name,
            name: "data",
            record_id: relation.select(:id)
          })
          .sum(:byte_size)
      end

      # Renders a 409 and returns true when the session's modality does not
      # match the upload surface (audio uploads to a document session or vice
      # versa), so callers can guard with `return if reject_wrong_modality(...)`.
      def reject_wrong_modality(session, expected)
        return false if session.modality == expected

        render_error(
          code: "validation_error",
          message: "this endpoint requires a #{expected} session (modality is #{session.modality})",
          status: :conflict
        )
        true
      end

      # Page count for one uploaded document: pdf-reader for PDFs (nil when the
      # PDF is encrypted/unparseable — the caller 422s), 1 for images.
      # Counts the pages of an UNTRUSTED PDF, on a Puma request thread. Two
      # things make that dangerous, and both are handled here.
      #
      # 1. Unbounded work. pdf-reader builds the xref table by reading a subsection
      #    header out of the file and looping that many times (xref.rb: `count =
      #    params[1].to_i` then `count.times`). The integer is attacker-supplied
      #    and Ruby's to_i is unbounded, so a 333-byte upload declaring
      #    `0 4000000000` spins for hours. With RAILS_MAX_THREADS defaulting to 3,
      #    three such uploads take down every endpoint for every account. The
      #    wall-clock bound is the fix; Timeout::Error is a StandardError, so the
      #    rescue below already turns an expiry into the same clean 422 a
      #    malformed PDF gets.
      #
      # 2. A lying page count. #page_count returns the catalog's self-declared
      #    /Count, which a hostile file sets to 1 while carrying 500 pages —
      #    understating itself past MAX_DOCUMENT_PAGES and past the per-page
      #    credit hold at commit, while still costing 500 pages of vision tokens.
      #    #pages is no better: it is literally `(1..page_count).map`, so it
      #    inherits the same lie. Only #page_references walks the real /Pages
      #    tree, and its length is what the provider will actually process.
      #    Walking is itself attacker-directed work, which is precisely why it
      #    runs inside the timeout.
      PDF_PARSE_TIMEOUT_SECONDS = 2

      def count_pages(upload, content_type)
        return 1 unless content_type == "application/pdf"

        upload.tempfile.rewind
        count = Timeout.timeout(PDF_PARSE_TIMEOUT_SECONDS) do
          reader = PDF::Reader.new(upload.tempfile)
          # Cross-checked against the declared count and resolved in favour of
          # whichever is larger, so neither an understated /Count nor a
          # truncated tree walk can get a document billed for less than it is.
          [ reader.objects.page_references.size, reader.page_count.to_i ].max
        end
        count.positive? ? count : nil
      # SystemStackError is caught explicitly because it is NOT a StandardError.
      # #page_references walks /Kids with no cycle guard, so a 238-byte PDF whose
      # /Pages node lists itself as its own kid recurses until the stack blows —
      # in milliseconds, well inside the timeout. Without this the walk turns a
      # file the old code accepted into a 500 on a public endpoint.
      rescue SystemStackError, StandardError
        nil
      ensure
        upload.tempfile.rewind if upload.tempfile.respond_to?(:rewind)
      end

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
        if session.modality_document?
          pages = [ session.document_pages, 1 ].max
          return (pages * COMMIT_ESTIMATE_RATE_PER_PAGE).round(6)
        end

        blob = session.audio_files.first
        seconds =
          if blob
            Scribe::AudioDuration.for_blob(blob).seconds.to_f
          elsif session.audio_chunks.exists?
            chunk_bytes = session.audio_chunks.with_attached_data
                                 .sum { |c| c.data.blob&.byte_size.to_i }
            chunk_bytes / Scribe::AudioDuration::ESTIMATE_BYTES_PER_SECOND
          else
            # Segments-only session: measured durations exist for every already-
            # transcribed segment; unsettled ones contribute 0 and the minute
            # floor below keeps the estimate positive.
            session.transcript_segments.sum(:duration_seconds).to_f
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
          :language_hint, :mode, :modality, :callback_url,
          outputs: [
            :type, :page_id, :template_ref, { context: {} },
            { fields: [ :key, :label, :type, :description, :minimum, :maximum, { enum: [] } ] }
          ]
        )
      end
    end
  end
end
