# Cross-Origin Resource Sharing.
#
# Scoped to the JSON API surface only. The browser scribe SDK (and any other
# cross-origin API client) needs CORS on `/api/*`; the HTML/admin/dashboard
# surfaces deliberately get NO CORS. Bearer tokens, not cookies, carry auth, so
# credentials stay off — never combine `origins "*"` with `credentials: true`.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/api/*",
             headers: :any,
             methods: [ :get, :post, :patch, :put, :options ],
             credentials: false
  end
end
