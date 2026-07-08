require "test_helper"

class CspHeaderTest < ActionDispatch::IntegrationTest
  test "sends a CSP report-only header on an HTML page" do
    get new_user_session_path
    assert_response :success

    header = response.headers["Content-Security-Policy-Report-Only"] ||
             response.headers["Content-Security-Policy"]
    assert header.present?, "expected a CSP header to be set"
    assert_includes header, "default-src 'self'"
    assert_includes header, "object-src 'none'"
  end
end
