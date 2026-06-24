# Metering & Billing

Every provider call is metered. Medispeak records one **usage event** per
physical adapter attempt, prices it from versioned price tables, and settles the
cost against a per-account **credit ledger**. This supports cost/observability,
per-model analytics, quotas, and client billing.

The code lives in `app/services/metering/` plus the `UsageEvent`,
`AccountCredit`, `CreditTransaction`, `ModelPrice`, and `AudioModelPrice` models.

---

## Usage events

`Metering::UsageRecorder.record` persists a `UsageEvent` from a normalized
`Llm::Result`:

| Column                     | Source |
|----------------------------|--------|
| `account` / `api_token`    | The owning account and (optionally) token. |
| `scribe_session_id` / `scribe_output_id` | The session and output the attempt belongs to (nil for v1). |
| `function`                 | `asr`, `structuring`, or `combined`. |
| `provider` / `model`       | From the result. |
| `input_tokens` / `output_tokens` / `total_tokens` | Token usage (0 for ASR). |
| `audio_seconds`            | Measured audio duration (0 for structuring). |
| `estimated`                | True when the provider omitted a usage block and usage was estimated. |
| `unit_price_input` / `unit_price_output` / `unit_price_audio_min` | Snapshotted unit prices used to compute the cost. |
| `cost` / `currency`        | The computed cost. |
| `latency_ms`               | Call latency where available. |
| `status`                   | `pending`, `finalized`, or `failed` (recorded as `finalized` by default). |

One usage event corresponds to one physical attempt. With a fallback, the
primary and the fallback attempt each produce their own event. A primary that
consumed tokens but returned a bad/truncated response is still recorded and
billed.

`UsageRecorder` is defensive: a `nil` usage block does not raise — tokens/audio
default to zero and `PriceBook` returns zero cost rather than failing.

---

## The price book

`Metering::PriceBook.cost(function:, provider:, model:, usage:, at:)` computes
the total cost from two versioned tables, selecting the row effective at the
given time (`ModelPrice.current(at)` / `AudioModelPrice.current(at)`):

- **`ModelPrice`** — token pricing: `input_per_million`, `output_per_million`,
  `currency`, `effective_at`, `deprecated_at`. Applied for `structuring` and
  `combined`.

  ```
  token_cost = input_tokens/1e6 * input_per_million
             + output_tokens/1e6 * output_per_million
  ```

- **`AudioModelPrice`** — per-minute pricing: `price_per_minute`, `currency`,
  `effective_at`, `deprecated_at`. Applied for `asr` and `combined`.

  ```
  audio_cost = audio_seconds/60 * price_per_minute
  ```

A `combined` event carries both audio and token cost. Costs are rounded to 6
decimal places. **A missing price row yields zero cost** (graceful degradation —
metering never blocks a call), so make sure price rows exist for every
provider/model you bill.

---

## Credit ledger

`Metering::QuotaGuard` enforces quotas against `AccountCredit` (authoritative
`balance`, `credit_limit`, `refill_period`) and an immutable
`CreditTransaction` ledger.

- **`hold!(account:, estimate:)`** — placed at commit. Inside a row-locked
  transaction it checks `balance - estimate >= 0`; if so it inserts a `hold`
  transaction and returns an `ok?` token, otherwise returns a not-ok token.
  (Note: v2 `commit` currently calls `hold!` with `estimate: 0` because the
  per-minute cost is not yet known at commit time.)
- **`deduct!(usage_event)`** — on finalize, inside a row-locked transaction it
  inserts a `deduction` transaction for the event's cost and lowers the balance.
- **`refund!(usage_event)`** — inserts a `refund` transaction and raises the
  balance (used to true up a failed attempt's hold).

**Concurrency & idempotency:** all balance mutations happen inside a transaction
with a row lock on the `AccountCredit`, so concurrent commits cannot oversell.
Deduction/refund is idempotent — the unique `(usage_event_id, txn_type)` index
turns a retried finalize into a no-op (`RecordNotUnique` is rescued) instead of a
double charge.

**Unlimited accounts:** an account with **no** `AccountCredit` row is treated as
unlimited — `hold!`/`deduct!`/`refund!` degrade to no-ops. This is why metering
in the orchestrator is best-effort and never fails a session.

`CreditTransaction` columns: `txn_type` (`hold`/`deduction`/`refund`/...),
`amount`, `balance_before`, `balance_after`, `usage_event_id`,
`scribe_session_id`.

---

## Quotas & rate limits

Two independent mechanisms:

1. **Credit balance** (above) — the ledger gates spend. A commit holds against
   the balance; finalize deducts; failures are refunded.
2. **Request rate limiting** — `rack-attack`
   (`config/initializers/rack_attack.rb`) throttles authenticated `/api/`
   traffic keyed on the **account id**, so minting more tokens does not raise the
   cap. The budget is the account's `settings["rpm"]` over a 60-second window
   (default **120 rpm**). Exceeding it returns **429** with `RateLimit-Limit`,
   `RateLimit-Remaining`, `RateLimit-Reset` (epoch seconds), and `Retry-After`
   headers. See the rate-limiting section of [api/v2.md](./api/v2.md).

---

## Reading usage: `GET /api/v2/usage`

The usage endpoint aggregates the account's **finalized** usage events:

```json
{
  "total_cost": 0.0123,
  "total_tokens": 4210,
  "total_audio_seconds": 95.0,
  "by_model": [
    { "model": "whisper-1",   "cost": 0.0095, "total_tokens": 0,    "audio_seconds": 95.0 },
    { "model": "gpt-4o-mini", "cost": 0.0028, "total_tokens": 4210, "audio_seconds": 0.0 }
  ]
}
```

- `total_cost` — sum of `cost` across finalized events.
- `total_tokens` — sum of `total_tokens`.
- `total_audio_seconds` — sum of `audio_seconds`.
- `by_model` — the same metrics grouped by `model`.

Only events with `status: "finalized"` are counted; `pending`/`failed` events are
excluded.

```bash
curl https://api.medispeak.example/api/v2/usage \
  -H "Authorization: Bearer $MSK_TOKEN"
```

See [architecture.md](./architecture.md) for where metering sits in the request
lifecycle.
