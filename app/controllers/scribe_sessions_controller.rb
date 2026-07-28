# Consultations: the clinician-facing record of a scribe session.
#
# Sessions are produced by the API (recorded audio or an uploaded document),
# never authored here, so this surface is strictly read-only: a filterable list
# and one page per session showing how far the pipeline got and what it
# produced.
class ScribeSessionsController < ApplicationController
  # One stage of the pipeline strip on the show page. `state` is one of
  # :done, :in_progress, :partial, :failed, :pending and is always DERIVED from
  # persisted data (attachments, transcript, output statuses) rather than read
  # off the session's own status column, which can lag behind or over-report.
  Stage = Struct.new(:label, :state, :detail, keyword_init: true)

  before_action :set_scribe_session, only: :show

  helper_method :status_filter, :modality_filter

  # GET /scribe_sessions
  def index
    sessions = policy_scope(ScribeSession)
                 .includes(:transcript, :scribe_outputs, :usage_events)
                 .order(created_at: :desc, id: :desc)

    # Filters are matched against the enum's own keys before they reach the
    # query, so an unknown or hostile value is simply ignored (never
    # interpolated).
    sessions = sessions.where(status: status_filter) if status_filter
    sessions = sessions.where(modality: modality_filter) if modality_filter

    @pagy, @scribe_sessions = paginate(sessions)
  end

  # GET /scribe_sessions/:id
  def show
    @pipeline = pipeline_stages(@scribe_session)
    # Ordered in Ruby: everything the page needs is already preloaded, so a
    # `.order` here would re-query the same rows.
    @outputs = @scribe_session.scribe_outputs.sort_by(&:id)
    @usage_events = @scribe_session.usage_events.sort_by { |event| [ event.created_at, event.id ] }
  end

  private

  def set_scribe_session
    @scribe_session = ScribeSession
                        .with_attached_audio_files
                        .with_attached_document_files
                        .includes(:transcript, :transcript_segments, :usage_events, scribe_outputs: :page)
                        .find(params[:id])
    authorize @scribe_session
  end

  # Pagy raises instead of clamping, and `page` is user input: a stale link
  # (?page=4 after the list shrank, or after a filter narrows it) raises
  # OverflowError and a junk value (?page=abc, ?page=0) raises VariableError.
  # Both would be a 500 on a page anyone can bookmark, so land on the nearest
  # real page instead.
  def paginate(sessions)
    pagy(sessions)
  rescue Pagy::OverflowError => e
    pagy(sessions, page: e.pagy.last)
  rescue Pagy::VariableError
    pagy(sessions, page: 1)
  end

  def status_filter
    params[:status].presence_in(ScribeSession.statuses.keys)
  end

  def modality_filter
    params[:modality].presence_in(ScribeSession.modalities.keys)
  end

  # --- Pipeline derivation ---------------------------------------------------

  def pipeline_stages(session)
    captured = captured?(session)

    [
      Stage.new(
        label: "Captured",
        state: capture_state(session, captured),
        detail: capture_detail(session, captured)
      ),
      Stage.new(
        # An OCR session has no speech; the same stage is where its text comes
        # from, so name it for what actually happened.
        label: session.modality_document? ? "Extracted" : "Transcribed",
        state: transcribe_state(session, captured),
        detail: transcribe_detail(session)
      ),
      Stage.new(
        label: "Structured",
        state: structure_state(session),
        detail: structure_detail(session)
      )
    ]
  end

  # A persisted transcript is itself proof of capture: nothing can be
  # transcribed that was not first recorded or uploaded. Needed because a row
  # can outlive its attachment (legacy sessions, media detached out of band),
  # and such a session must not report that nothing was ever captured.
  def captured?(session)
    session.audio_files.attached? ||
      session.document_files.attached? ||
      session.transcript_segments.any?
  end

  def capture_state(session, captured)
    return :done if captured || session.transcript.present?
    return :failed if session.failed?
    return :in_progress if session.created? || session.uploading?

    :pending
  end

  def capture_detail(session, captured)
    # Transcribed, but the file itself is not on the record any more. Say only
    # that — nothing in this app deletes media, so claiming it was purged would
    # be a guess.
    return "Media is no longer attached" if !captured && session.transcript.present?

    if session.modality_document?
      return "No documents uploaded" unless captured

      pages = session.document_pages.to_i
      count = session.document_files.size
      [ pluralize(count, "document"), (pluralize(pages, "page") if pages.positive?) ].compact.join(", ")
    else
      segments = session.transcript_segments.size
      return pluralize(segments, "segment") if segments.positive?
      return "No audio uploaded" unless captured

      pluralize(session.audio_files.size, "audio file")
    end
  end

  def transcribe_state(session, captured)
    return :done if session.transcript.present?
    return :failed if session.failed?
    return :in_progress if session.live_transcript.present?
    return :in_progress if captured && (session.uploading? || session.processing?)

    :pending
  end

  def transcribe_detail(session)
    transcript = session.transcript
    if transcript.present?
      words = transcript.text.to_s.split.size
      return [ transcript.provider.presence, pluralize(words, "word") ].compact.join(" · ")
    end

    return "Partial text available" if session.live_transcript.present?
    return "No text was produced" if session.failed?

    if session.modality_document?
      "Waiting for the document to be read"
    else
      "Waiting for the recording to be committed"
    end
  end

  # Structuring is finished only when every output has left :pending; a mix of
  # settled outcomes is reported as partial rather than rounded up to done.
  def structure_state(session)
    outputs = session.scribe_outputs.to_a
    return :pending if outputs.empty?

    unsettled = outputs.select(&:status_pending?)
    return session.failed? ? :failed : :in_progress if unsettled.any?
    return :failed if outputs.all?(&:status_failure?)
    return :partial if outputs.any? { |o| o.status_failure? || o.status_partial? }

    :done
  end

  def structure_detail(session)
    outputs = session.scribe_outputs.to_a
    return "No outputs were requested" if outputs.empty?

    "#{outputs.count(&:status_success?)} of #{pluralize(outputs.size, 'output')} ready"
  end

  # Stage details read as sentences, so they need the same pluralization the
  # views use.
  def pluralize(count, singular)
    helpers.pluralize(count, singular)
  end
end
