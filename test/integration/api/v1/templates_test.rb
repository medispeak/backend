require "test_helper"

class Api::V1::TemplatesTest < ActionDispatch::IntegrationTest
  setup do
    @token = create(:api_token)
    @account = @token.account
    @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
  end

  test "show returns the template with nested pages and form fields" do
    template = create(:template)
    page = create(:page, template: template)
    create(:form_field, page: page, title: "complaint")

    get "/api/v1/templates/#{template.id}", headers: @headers

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal template.id, body["id"]
    assert_equal 1, body["pages"].size
    assert_equal page.id, body["pages"][0]["id"]
    assert_equal 1, body["pages"][0]["form_fields"].size
  end

  test "find_by_domain resolves the template from the Origin host" do
    template = create(:template)
    page = create(:page, template: template)
    create(:form_field, page: page, title: "complaint")
    Domain.create!(fqdn: "clinic.example.com", template: template)

    get "/api/v1/templates/find_by_domain",
        headers: @headers.merge("Origin" => "https://clinic.example.com")

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal template.id, body["id"]
    assert_equal 1, body["pages"][0]["form_fields"].size
  end

  test "find_by_domain issues a bounded query count regardless of page/field counts" do
    # Small template: 1 page, 1 field.
    small = create(:template)
    small_page = create(:page, template: small)
    create(:form_field, page: small_page)
    Domain.create!(fqdn: "small.example.com", template: small)

    q_small = count_ar_queries do
      get "/api/v1/templates/find_by_domain",
          headers: @headers.merge("Origin" => "https://small.example.com")
    end
    assert_response :ok

    # Large template: 3 pages, 3 fields each.
    large = create(:template)
    3.times do
      p = create(:page, template: large)
      3.times { create(:form_field, page: p) }
    end
    Domain.create!(fqdn: "large.example.com", template: large)

    q_large = count_ar_queries do
      get "/api/v1/templates/find_by_domain",
          headers: @headers.merge("Origin" => "https://large.example.com")
    end
    assert_response :ok

    assert_equal q_small, q_large,
      "query count grew with more pages/fields -> N+1 not fixed (got #{q_small} then #{q_large})"
  end

  test "find_by_domain returns 404 for an unknown domain" do
    get "/api/v1/templates/find_by_domain",
        headers: @headers.merge("Origin" => "https://nope.example.com")

    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
  end

  test "unauthenticated request is rejected" do
    get "/api/v1/templates/find_by_domain"
    assert_response :unauthorized
  end

  private

  # Counts real ActiveRecord SELECT/INSERT/UPDATE/DELETE queries issued inside
  # the block, ignoring schema reflection, cache hits, and transaction control
  # statements. Used to prove the render does not N+1 across pages/fields.
  def count_ar_queries
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if payload[:name] == "SCHEMA"
      next if payload[:sql].to_s =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW)\b/i

      count += 1
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
