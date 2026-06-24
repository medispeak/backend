module ExceptionHandler
  extend ActiveSupport::Concern

  private

  def handle_global_exception(err)
    if err.is_a?(::GenericException)
      Rails.logger.error(err.message)
      render_error_response(err.message, err.code)
    else
      handle_uncaught_error(err)
    end
  end

  def handle_uncaught_error(err)
    log_error(err)
    # Never interpolate err.message into the client response (CWE-209): raw
    # exception text can leak internals. Detail stays in the logs above.
    render_error_response(
      "An unexpected error occurred.",
      :internal_server_error
    )
  end

  def log_error(err)
    Rails.logger.error("Unhandled Exception: #{err.message}")
    Rails.logger.error(err.backtrace.join("\n")) if err.backtrace
  end

  def render_error_response(message, code)
    render json: {
      error: {
        message: message,
        code: code,
        request_id: request.request_id
      }
    }, status: code
  end
end
