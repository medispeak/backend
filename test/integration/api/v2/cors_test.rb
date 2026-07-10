require "test_helper"

class Api::V2::CorsTest < ActionDispatch::IntegrationTest
  test "api routes are CORS-enabled for cross-origin requests" do
    get "/api/v2/config",
        headers: { "Origin" => "https://app.example.com", "Authorization" => "Bearer nope" }
    # origins "*" answers with a wildcard ACAO (credentials are off).
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "non-api routes are not CORS-enabled" do
    get "/up", headers: { "Origin" => "https://app.example.com" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
