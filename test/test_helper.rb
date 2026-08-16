ENV["RAILS_ENV"] ||= "test"

# The suite must not depend on ambient credentials: it should pass on a clean
# checkout with no .env and no CI secrets. Outbound HTTP is blocked by WebMock
# below, so these placeholders are never used against a real provider — they
# exist because the OpenAI client refuses to build without a token. A real value
# in the environment still wins.
ENV["OPENAI_ACCESS_TOKEN"] ||= "test-openai-token"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |f| require f }

# All external provider HTTP must be stubbed in tests.
WebMock.disable_net_connect!(allow_localhost: true)

# Ensure routes are drawn (without force-reloading) so Devise mappings are
# populated before any admin integration test signs in. Route drawing is
# otherwise lazy in the test env, which made admin `sign_in` fail intermittently
# depending on test order.
Rails.application.routes_reloader.execute_unless_loaded

module ActiveSupport
  class TestCase
    # Single process: forked parallel workers crash on macOS (Objective-C
    # fork-safety) once the suite crosses the 50-test threshold. The suite is
    # fast enough that parallelism isn't needed.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Factory Bot shorthand (build/create/...) in all tests.
    include FactoryBot::Syntax::Methods

    # Add more helper methods to be used by all tests here...
  end
end
