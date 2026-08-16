# The template playground: run a real scribe session against one of your own
# templates, from the browser, without integrating the SDK first.
#
# This controller deliberately owns only the two operations the v2 API restricts
# to an account token (`require_account_token!` in
# Api::V2::ScribeSessionsController): creating a session, and minting a scoped
# token for it. Audio upload, commit and polling go from the browser straight to
# /api/v2 carrying the short-lived `mss_` token minted here, so the playground
# exercises the same public API a customer integrates against — every guard,
# every 402, every error envelope — instead of a private shortcut that could
# pass while the real API is broken.
#
# The account secret (`msk_live_…`) never reaches the browser.
class PlaygroundController < ApplicationController
  before_action :set_template

  # What the browser may ask for. A document run uploads a lab report to
  # /documents and is extracted by vision OCR; an audio run records and uploads
  # utterances to /audio/segments. Everything after the transcript exists is the
  # same pipeline, which is exactly what makes running both from here worth it.
  MODALITIES = %w[audio document].freeze

  # GET /templates/:template_id/playground
  def show
    # `set_template` already loaded the runnable pages, ordered and preloaded:
    # a template's pages are a sequence, and the view walks every field.
  end

  # POST /templates/:template_id/playground/sessions
  #
  # One session, one `form` output per page — which is what a production
  # integration posts for a multi-page template, and therefore what the
  # playground must post to be worth trusting.
  def create_session
    authorize ScribeSession, :create?

    if @pages_with_fields.empty?
      return render json: {
        error: { code: "validation_error", message: "This template has no fields to fill in yet." }
      }, status: :unprocessable_entity
    end

    result = Scribe::SessionBuilder.new(
      account: current_account,
      user: current_user,
      outputs: @pages_with_fields.map { |page| { type: "form", page_id: page.id } },
      mode: "consultation",
      modality: modality,
      language_hint: language_hint
    ).call

    unless result.success?
      return render json: { error: result.error }, status: :unprocessable_entity
    end

    token, expires_at = Scribe::SessionToken.mint(result.session)

    render json: {
      session_id: result.session.id,
      token: token,
      expires_at: expires_at.iso8601,
      modality: result.session.modality,
      pages: @pages_with_fields.map do |page|
        {
          id: page.id,
          name: page.name,
          # `title` is the machine key the structuring model fills in, and the
          # key the result JSON comes back under (Scribe::SchemaBuilder keys by
          # title, not friendly_name). The browser matches on it; it shows
          # friendly_name.
          fields: page.form_fields.sort_by(&:id).map do |field|
            { key: field.title, label: field.friendly_name.presence || field.title }
          end
        }
      end
    }, status: :created
  end

  # POST /templates/:template_id/playground/sessions/:session_id/token
  #
  # The `mss_` TTL is 15 minutes and an expired token is indistinguishable from
  # an invalid one (both are a bodyless 401), so the browser re-mints on its
  # first 401 rather than trying to predict expiry.
  def mint_token
    authorize ScribeSession, :create?

    session = policy_scope(ScribeSession).find_by(id: params[:session_id])
    return head :not_found if session.nil?

    token, expires_at = Scribe::SessionToken.mint(session)
    render json: { token: token, expires_at: expires_at.iso8601 }
  end

  # GET /templates/:template_id/playground/result?session_id=…
  #
  # Returns the finished outputs as an HTML fragment rendered through the same
  # partial the consultation view uses, so the playground and /scribe_sessions
  # cannot drift apart in how a result reads.
  def result
    # The segments' attachments come along because the result now plays the
    # recording back, and asking each segment for its blob one at a time is a
    # query per segment on a page that has just made dozens of them.
    session = policy_scope(ScribeSession)
                .with_attached_audio_files
                .includes(transcript_segments: { data_attachment: :blob })
                .find_by(id: params[:session_id])
    if session.nil?
      skip_authorization
      return head :not_found
    end
    authorize session, :show?

    render partial: "playground/result",
           locals: { session: session, outputs: session.scribe_outputs.order(:id).includes(:page) }
  end

  private

  def set_template
    @template = Template.find(params[:template_id])
    authorize @template, :show?
    # A page with no fields has nothing for the model to fill and would just be
    # a `form` output that always comes back empty, so it is left out of the run.
    @pages_with_fields = @template.pages.includes(:form_fields).order(:id).select { |page| page.form_fields.any? }
  rescue ActiveRecord::RecordNotFound
    redirect_to templates_path, alert: "That template no longer exists."
  end

  # `auto` is a sentinel meaning "no hint" (Scribe::AsrStage::AUTO_DETECT) — it
  # is not a language code, and sending it as one 400'd every Sarvam segment in
  # production on 2026-08-16. Passing it through is correct precisely because
  # the stage special-cases it.
  def language_hint
    params[:language_hint].presence || "auto"
  end

  # Anything unrecognised runs as audio rather than 422-ing: the modality is a
  # UI affordance here, not a contract, and SessionBuilder would reject a bad
  # value with an error the playground has no useful way to explain.
  def modality
    MODALITIES.include?(params[:modality]) ? params[:modality] : "audio"
  end
end
