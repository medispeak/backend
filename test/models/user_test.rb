require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "gets a default account on create" do
    user = create(:user)
    assert user.account.present?
    assert user.account.persisted?
  end
end
