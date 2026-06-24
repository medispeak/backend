ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# All external provider HTTP must be stubbed in tests.
WebMock.disable_net_connect!(allow_localhost: true)

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
