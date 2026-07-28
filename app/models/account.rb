class Account < ApplicationRecord
  # Maximum tree depth (a root counts as 1): org -> program -> facility ->
  # sub-facility. Also the hard bound on every runtime tree walk, so even
  # corrupted parent data can never loop forever.
  MAX_DEPTH = 4

  belongs_to :parent, class_name: "Account", optional: true
  # A node with children cannot be deleted — reparent or delete them first.
  # (Deleting a mid-tree node would silently detach a whole subtree.)
  has_many :children, class_name: "Account", foreign_key: :parent_id,
           dependent: :restrict_with_error, inverse_of: :parent

  has_many :users, dependent: :nullify
  has_many :api_tokens, dependent: :destroy
  has_one :account_credit, dependent: :destroy
  has_many :usage_events, dependent: :nullify
  has_many :usage_limits, dependent: :destroy

  validates :name, presence: true
  validates :status, presence: true
  validate :parent_creates_no_cycle_and_fits_depth

  before_create :ensure_webhook_secret

  # Ancestor chain, nearest first (parent, grandparent, ...). An in-Ruby walk:
  # trees are at most MAX_DEPTH deep and tiny, so ≤3 single-row lookups beat
  # any recursive-CTE machinery. Depth-capped so corrupt data degrades to a
  # truncated chain, never an infinite loop.
  def ancestors
    chain = []
    node = self
    while (node = node.parent)
      break if chain.size >= MAX_DEPTH
      chain << node
    end
    chain
  end

  # [self, parent, ..., root] — the model-config / limit resolution order
  # (most specific first).
  def self_and_ancestors
    [ self, *ancestors ]
  end

  # Every account id in this node's subtree (self included). Iterative BFS,
  # ≤ MAX_DEPTH-1 indexed queries over small trees. Used for subtree limits
  # and usage rollups.
  def subtree_ids
    ids = [ id ]
    frontier = [ id ]
    (MAX_DEPTH - 1).times do
      frontier = Account.where(parent_id: frontier).pluck(:id)
      break if frontier.empty?
      ids.concat(frontier)
    end
    ids
  end

  # Scalar summaries for the admin dashboard (avoids linking to dashboard-less
  # AccountCredit / ApiToken resources).
  def credit_balance
    account_credit&.balance&.to_s || "—"
  end

  def api_tokens_count
    api_tokens.count
  end

  private

  # Walking UP from the proposed parent catches every cycle: if any ancestor of
  # the new parent is self (or repeats), the reparent is rejected. The same walk
  # measures depth against MAX_DEPTH.
  def parent_creates_no_cycle_and_fits_depth
    return if parent_id.nil?

    if parent_id == id
      errors.add(:parent_id, "cannot be the account itself")
      return
    end

    seen = Set[id]
    node = parent
    depth = 1
    while node
      if seen.include?(node.id)
        errors.add(:parent_id, "would create a cycle")
        return
      end
      seen << node.id
      depth += 1
      if depth > MAX_DEPTH
        errors.add(:parent_id, "exceeds the maximum tree depth of #{MAX_DEPTH}")
        return
      end
      node = node.parent
    end
  end

  def ensure_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(32)
  end
end
