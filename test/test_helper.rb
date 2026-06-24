ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# All external provider HTTP must be stubbed in tests.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Factory Bot shorthand (build/create/...) in all tests.
    include FactoryBot::Syntax::Methods

    # Add more helper methods to be used by all tests here...
  end
end
