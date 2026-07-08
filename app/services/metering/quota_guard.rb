module Metering
  # Ledger-backed quota enforcement against AccountCredit + CreditTransaction.
  #
  # All balance mutations happen inside a transaction with a row lock on the
  # AccountCredit so concurrent commits can't oversell. Deduction is idempotent:
  # the unique (usage_event_id, txn_type) index turns a retried finalize into a
  # no-op instead of a double charge. Accounts without an AccountCredit row are
  # treated as unlimited — hold!/deduct!/refund! degrade to no-ops.
  class QuotaGuard
    # Result of a hold attempt. `ok?` tells the caller whether to proceed.
    # `transaction` is the persisted hold (nil for the unlimited no-op case).
    Token = Struct.new(:ok, :transaction, :unlimited, keyword_init: true) do
      def ok?
        !!ok
      end

      def unlimited?
        !!unlimited
      end
    end

    class InsufficientCredit < StandardError; end

    class << self
      def hold!(account:, estimate:)
        credit = AccountCredit.find_by(account_id: account.id)
        return Token.new(ok: true, transaction: nil, unlimited: true) if credit.nil?

        estimate = estimate.to_d

        AccountCredit.transaction do
          credit.lock!
          if credit.balance - estimate < 0
            return Token.new(ok: false, transaction: nil, unlimited: false)
          end

          txn = CreditTransaction.create!(
            account_id: account.id,
            txn_type: :hold,
            amount: estimate,
            balance_before: credit.balance,
            balance_after: credit.balance
          )
          Token.new(ok: true, transaction: txn, unlimited: false)
        end
      end

      def deduct!(usage_event)
        amount = usage_event.cost.to_d
        apply_settlement(usage_event, :deduction, amount, sign: -1)
      end

      def refund!(usage_event)
        amount = usage_event.cost.to_d
        apply_settlement(usage_event, :refund, amount, sign: 1)
      end

      private

      # Inserts a ledger row + adjusts balance inside one locked transaction.
      # The unique (usage_event_id, txn_type) index makes a retry idempotent:
      # a duplicate insert raises RecordNotUnique and we treat it as a no-op.
      def apply_settlement(usage_event, txn_type, amount, sign:)
        credit = AccountCredit.find_by(account_id: usage_event.account_id)
        return nil if credit.nil?

        AccountCredit.transaction(requires_new: true) do
          credit.lock!
          balance_before = credit.balance
          balance_after = balance_before + (amount * sign)
          # Hard-block billing floor: a deduction never drives the persisted
          # ledger negative. The full deduction is still recorded (the charge
          # occurred, at its real amount) but balance_after is clamped at zero.
          # Refunds (sign: +1) are unaffected. See plan 002.
          balance_after = [ balance_after, 0 ].max if sign.negative?

          txn = CreditTransaction.create!(
            account_id: usage_event.account_id,
            txn_type: txn_type,
            amount: amount,
            balance_before: balance_before,
            balance_after: balance_after,
            usage_event_id: usage_event.id
          )
          credit.update!(balance: balance_after)
          txn
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end
