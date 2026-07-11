module Admin
  # Base for admin resources that are inspection-only (scribe sessions and their
  # associated data). The routes are declared `only: [:index, :show]`, so the
  # mutating routes do not exist and Administrate hides their buttons; this hook
  # is defense-in-depth so new/create/edit/update/destroy are never offered even
  # if a route is added later.
  class ReadOnlyController < Admin::ApplicationController
    READ_ONLY_BLOCKED_ACTIONS = %w[new create edit update destroy].freeze

    def existing_action?(resource, action_name)
      return false if READ_ONLY_BLOCKED_ACTIONS.include?(action_name.to_s)

      super
    end
    helper_method :existing_action?
  end
end
