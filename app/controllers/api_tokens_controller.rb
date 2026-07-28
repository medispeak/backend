# API keys authenticate a customer's server against the Medispeak API.
#
# The plaintext key only ever exists on the instance that minted it
# (ApiToken#raw_token — everything persisted is a SHA-256 digest), so `create`
# hands it to the next request through the flash and `show` reveals it exactly
# once. Nothing here can recover a key after that.
class ApiTokensController < ApplicationController
  before_action :set_api_token, only: [ :show, :destroy ]

  helper_method :api_token_state, :expiry_options

  # The model requires an expiry, so the form offers durations instead of a
  # free-form date picker. The values are real timestamps because `create`
  # casts the submitted `expires_at` straight onto the record — that contract
  # (params[:api_token][:name] and [:expires_at]) is what the API expects.
  EXPIRY_CHOICES = [
    [ "30 days", 30 ],
    [ "60 days", 60 ],
    [ "90 days", 90 ],
    [ "6 months", 180 ],
    [ "1 year", 365 ]
  ].freeze

  DEFAULT_EXPIRY_DAYS = 90

  # GET /api_tokens
  def index
    @api_tokens = policy_scope(ApiToken).order(active: :desc, created_at: :desc)
  end

  # GET /api_tokens/1
  def show
    # Reveal-once: `create` hands the plaintext key to this request through the
    # flash. It is only this key's secret if it starts with this key's prefix —
    # a flash that outlived its redirect (a lost response, a second tab) must
    # never surface one key's secret on another key's page.
    raw = flash[:raw_token].to_s
    prefix = @api_token.token_prefix.to_s
    @raw_token = raw if prefix.present? && raw.start_with?(prefix)
  end

  # GET /api_tokens/new
  def new
    @api_token = current_user.api_tokens.new(expires_at: expires_in(DEFAULT_EXPIRY_DAYS))
    authorize @api_token
  end

  # POST /api_tokens
  def create
    @api_token = current_user.api_tokens.new(api_token_params)
    authorize @api_token

    if @api_token.save
      # Reveal-once: the key rides in the flash to the show page and is swept
      # after that single render.
      flash[:raw_token] = @api_token.raw_token
      redirect_to @api_token, notice: "API key created. Copy it now — it will not be shown again."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # DELETE /api_tokens/1
  # A soft revoke: the row stays so the key remains auditable, but it can no
  # longer authenticate.
  #
  # Validations are skipped deliberately. `name` and `expires_at` became
  # required after the table shipped, so rows minted before that fail today's
  # validations; `update` would return false and this action would still
  # redirect saying "revoked" while the key stayed live. A revoke must never
  # report success it did not achieve.
  def destroy
    @api_token.active = false

    if @api_token.save(validate: false)
      redirect_to api_tokens_path, notice: "API key revoked."
    else
      redirect_to api_tokens_path, alert: "Could not revoke that API key. Please try again."
    end
  end

  private

  # Pundit resolves ownership, so a key belonging to someone else is a denial
  # (redirect with an alert) rather than a 404.
  def set_api_token
    @api_token = ApiToken.find(params[:id])
    authorize @api_token
  end

  def api_token_params
    params.require(:api_token).permit(:name, :expires_at)
  end

  # [label, badge class] for a key's real state. Revoked beats expired beats
  # active: `active` stays true on a key that has simply aged out, and calling
  # such a key "Active" in the table would be a lie — ApiToken.authenticate
  # already rejects it.
  #
  # A missing expires_at counts as expired for the same reason: the `active`
  # scope behind ApiToken.authenticate filters on `expires_at > now`, which NULL
  # never satisfies, so a key with no expiry cannot authenticate either.
  def api_token_state(token)
    return [ "Revoked", "badge-failed" ] unless token.active?
    return [ "Expired", "badge-neutral" ] if token.expires_at.blank? || token.expires_at.past?

    [ "Active", "badge-success" ]
  end

  # Select options for the expiry field. Values are normalised to the end of
  # the target day so the same choice produces the same string across a
  # render/re-render pair and the selection survives a validation error.
  def expiry_options
    EXPIRY_CHOICES.map do |label, days|
      at = expires_in(days)
      [ "#{label} — #{at.strftime('%-d %b %Y')}", at.iso8601 ]
    end
  end

  def expires_in(days)
    days.days.from_now.to_date.end_of_day
  end
end
