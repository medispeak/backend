require "test_helper"

class TemplatePolicyTest < ActiveSupport::TestCase
  setup do
    @account_a = create(:account)
    @user_a = create(:user, account: @account_a)
    @account_b = create(:account)
    @user_b = create(:user, account: @account_b)
    @b_template = create(:template, account: @account_b)
  end

  test "denies update on another account's template" do
    assert_not TemplatePolicy.new(@user_a, @b_template).update?
  end

  test "denies destroy on another account's template" do
    assert_not TemplatePolicy.new(@user_a, @b_template).destroy?
  end

  test "denies edit on another account's template" do
    assert_not TemplatePolicy.new(@user_a, @b_template).edit?
  end

  test "allows the owner to update and destroy" do
    assert TemplatePolicy.new(@user_b, @b_template).update?
    assert TemplatePolicy.new(@user_b, @b_template).destroy?
  end

  test "allows an admin to update and destroy any account's template" do
    admin = create(:user, account: @account_a, admin: true)
    assert TemplatePolicy.new(admin, @b_template).update?
    assert TemplatePolicy.new(admin, @b_template).destroy?
  end

  test "denies a non-admin editing a legacy template with no owner" do
    legacy = create(:template)
    assert_nil legacy.account_id
    assert_not TemplatePolicy.new(@user_a, legacy).update?
  end

  test "allows an admin to edit a legacy template with no owner" do
    admin = create(:user, account: @account_a, admin: true)
    legacy = create(:template)
    assert TemplatePolicy.new(admin, legacy).update?
  end

  test "scope returns only the user's account templates" do
    create(:template, account: @account_a)
    scoped = TemplatePolicy::Scope.new(@user_a, Template.all).resolve
    assert scoped.all? { |t| t.account_id == @account_a.id }
    assert_not_includes scoped, @b_template
  end

  test "scope returns all templates for an admin" do
    admin = create(:user, account: @account_a, admin: true)
    scoped = TemplatePolicy::Scope.new(admin, Template.all).resolve
    assert_includes scoped, @b_template
  end
end
