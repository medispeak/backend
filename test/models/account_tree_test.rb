require "test_helper"

# Tenancy tree semantics: parent_id walks, cycle/depth validation, and
# restricted deletion. Trees are ≤ Account::MAX_DEPTH and every runtime walk is
# depth-capped, so corrupt data can degrade but never loop.
class AccountTreeTest < ActiveSupport::TestCase
  def build_tree
    org = create(:account, name: "Org")
    program = create(:account, name: "Program", parent: org)
    facility = create(:account, name: "Facility", parent: program)
    [ org, program, facility ]
  end

  test "ancestors and self_and_ancestors walk nearest-first to the root" do
    org, program, facility = build_tree

    assert_equal [ program, org ], facility.ancestors
    assert_equal [ facility, program, org ], facility.self_and_ancestors
    assert_equal [], org.ancestors
  end

  test "subtree_ids covers self, children, and grandchildren" do
    org, program, facility = build_tree
    sibling = create(:account, name: "Program B", parent: org)

    assert_equal [ org.id, program.id, sibling.id, facility.id ].sort, org.subtree_ids.sort
    assert_equal [ program.id, facility.id ].sort, program.subtree_ids.sort
    assert_equal [ facility.id ], facility.subtree_ids
  end

  test "an account cannot be its own parent" do
    org = create(:account)
    org.parent_id = org.id

    assert_not org.valid?
    assert_includes org.errors[:parent_id].join, "itself"
  end

  test "reparenting under a descendant is rejected as a cycle" do
    org, _program, facility = build_tree
    org.parent = facility

    assert_not org.valid?
    assert_includes org.errors[:parent_id].join, "cycle"
  end

  test "a parent chain deeper than MAX_DEPTH is rejected" do
    _org, _program, facility = build_tree
    leaf = create(:account, name: "Leaf", parent: facility) # depth 4: OK
    too_deep = build(:account, name: "Too deep", parent: leaf)

    assert_not too_deep.valid?
    assert_includes too_deep.errors[:parent_id].join, "depth"
  end

  test "a node with children cannot be deleted" do
    org, _program, _facility = build_tree

    assert_not org.destroy
    assert org.errors[:base].any?
    assert Account.exists?(org.id)
  end

  test "existing flat accounts are unaffected roots" do
    account = create(:account)

    assert_nil account.parent
    assert_equal [ account ], account.self_and_ancestors
    assert_equal [ account.id ], account.subtree_ids
  end
end
