module Admin
  class UsageEventsController < Admin::ApplicationController
    # Usage events are an immutable metering ledger: index/show only.
    #
    # The route is declared `only: [:index, :show]`, so the mutating routes do
    # not exist and Administrate already hides their buttons. We also override
    # the authorization hook (`existing_action?` is the live hook in this
    # Administrate version; the older `valid_action?` is deprecated) as
    # defense-in-depth so new/create/edit/update/destroy are never offered.
    READ_ONLY_BLOCKED_ACTIONS = %w[new create edit update destroy].freeze

    def existing_action?(resource, action_name)
      return false if READ_ONLY_BLOCKED_ACTIONS.include?(action_name.to_s)

      super
    end
    helper_method :existing_action?
  end
end
