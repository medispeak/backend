module Api
  module V2
    # Base controller for the async, metered public v2 API. Bearer auth,
    # account-scoping, a stable error envelope, and Idempotency-Key support.
    class BaseController < ApplicationController
      include ExceptionHandler

      rescue_from Exception, with: :handle_global_exception

      skip_before_action :verify_authenticity_token
      before_action :authenticate!

      private

      # A request is authenticated if it carries EITHER a live account API token
      # OR a valid scoped session token. Account-only actions layer
      # `require_account_token!` on top; session-scoped actions resolve the
      # session through `find_session`, which enforces the token's `sid`.
      def authenticate!
        return if current_api_token || current_session_claims

        head :unauthorized
      end

      # Memoized active-token resolution (digest lookup + active/expiry scope
      # enforced inside ApiToken.authenticate).
      def current_api_token
        return @current_api_token if defined?(@current_api_token)

        @current_api_token = ApiToken.authenticate(bearer_token)
      end

      # Memoized scoped session-token claims (`{ "sid" => Integer, "scope" =>
      # [...] }`) or nil. Verification is a signature+expiry check — no DB row.
      def current_session_claims
        return @current_session_claims if defined?(@current_session_claims)

        @current_session_claims = Scribe::SessionToken.verify(bearer_token)
      end

      def current_account
        current_api_token&.account
      end

      # Account-only actions (create/index/tokens/config/usage) call this so a
      # session-scoped token can never reach an account-wide surface.
      def require_account_token!
        head :unauthorized unless current_api_token
      end

      def bearer_token
        request.headers.fetch("Authorization", "").to_s.split(" ").last
      end

      # Stable error envelope shared by every v2 endpoint.
      def render_error(code:, message:, status:, details: {})
        render json: {
          error: {
            code: code,
            message: message,
            request_id: request.request_id,
            details: details
          }
        }, status: status
      end

      # Idempotent execution keyed on the client's `Idempotency-Key` header.
      #
      # - No header: just yield (no idempotency bookkeeping).
      # - Fresh stored record, same fingerprint: replay the stored response.
      # - Fresh stored record, different fingerprint: 409 conflict.
      # - Otherwise: yield, then persist the rendered response for ~24h.
      def with_idempotency(fingerprint)
        key = idempotency_key_header
        # Skip the idempotency store when there is no key OR no account token.
        # Session-scoped tokens carry no ApiToken, and IdempotencyKey.api_token_id
        # is NOT NULL — persisting one would raise AFTER the block already ran
        # (billing the account and enqueuing the job), turning a successful commit
        # into a 500. commit's own status guard is the real dedup for that path.
        return yield if key.blank? || current_api_token.nil?

        existing = IdempotencyKey.fresh.find_by(api_token: current_api_token, key: key)

        if existing
          if existing.request_fingerprint == fingerprint
            render json: existing.response_body, status: existing.response_status
            return
          else
            render_error(
              code: "validation_error",
              message: "Idempotency-Key reuse with a different request payload",
              status: :conflict
            )
            return
          end
        end

        yield

        IdempotencyKey.create!(
          api_token: current_api_token,
          key: key,
          request_fingerprint: fingerprint,
          response_body: response_body_json,
          response_status: response.status,
          expires_at: 24.hours.from_now
        )
      end

      def idempotency_key_header
        request.headers["Idempotency-Key"].presence
      end

      # Parse the JSON the action just rendered so it can be replayed verbatim.
      def response_body_json
        JSON.parse(response.body)
      rescue JSON::ParserError, TypeError
        nil
      end
    end
  end
end
