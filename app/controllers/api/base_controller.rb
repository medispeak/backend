class Api::BaseController < ApplicationController
  include ExceptionHandler

  rescue_from Exception, with: :handle_global_exception

  skip_before_action :verify_authenticity_token
  prepend_before_action :authenticate_api_token!

  private

  def authenticate_api_token!
    if (user = user_from_token)
      sign_in user, store: false
    else
      head :unauthorized
    end
  end

  def token_from_header
    request.headers.fetch("Authorization", "").split(" ").last
  end

  # Digest-based lookup that also enforces active + not-expired (fixes the
  # previous plaintext find_by that ignored the active scope, CWE-613).
  def api_token
    @_api_token ||= ApiToken.authenticate(token_from_header)
  end

  def current_account
    api_token&.account
  end

  def user_from_token
    return unless api_token

    api_token.touch(:last_used_at)
    api_token.user
  end
end
