# A database-side backstop for ScribeSession::MAX_DOCUMENT_PAGES.
#
# The page ceiling is what sizes the OCR request and the per-page credit hold at
# commit, and until now it was enforced only by an unlocked read-check-write in
# Api::V2::ScribeSessionsController#documents. That check is now taken under a
# row lock, but a lock only binds code that remembers to take it — a console
# session, a future write path, or a bulk update can still push the counter past
# the cap. This makes the invariant true of the column itself.
#
# Any row already over the cap is clamped FIRST, deliberately. `NOT VALID` skips
# the historical scan but still enforces on every subsequent INSERT and UPDATE,
# whatever columns it touches — so an untouched over-cap row would become
# permanently unwritable, and the very next `status` update (commit's atomic
# claim, or the orchestrator's rollup) would raise CheckViolation and 500 the
# session forever. Leaving the constraint unvalidated without clamping trades a
# silent cap breach for a hard outage on exactly the affected rows.
#
# Clamping is safe for billing: the billed page quantity lives in
# usage_events.pages, an immutable per-attempt ledger. scribe_sessions.document_pages
# is only the running counter the caps and the hold are computed from, so
# correcting it rewrites no charge that was ever made.
#
# The literal 20 is deliberately duplicated from ScribeSession::MAX_DOCUMENT_PAGES
# rather than interpolated: a migration must keep meaning what it meant on the
# day it ran, even after the constant moves.
class ConstrainDocumentPages < ActiveRecord::Migration[8.1]
  CAP = 20

  def up
    over = execute("SELECT count(*) FROM scribe_sessions WHERE document_pages > #{CAP}")
             .first.fetch("count").to_i
    if over.positive?
      say "clamping #{over} scribe_sessions row(s) with document_pages > #{CAP}"
      execute "UPDATE scribe_sessions SET document_pages = #{CAP} WHERE document_pages > #{CAP}"
    end

    add_check_constraint :scribe_sessions,
                         "document_pages >= 0 AND document_pages <= #{CAP}",
                         name: "scribe_sessions_document_pages_within_cap",
                         validate: false
  end

  def down
    remove_check_constraint :scribe_sessions, name: "scribe_sessions_document_pages_within_cap"
  end
end
