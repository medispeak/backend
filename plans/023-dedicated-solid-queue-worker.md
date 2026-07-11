# Plan 023: Run Solid Queue in a dedicated worker so scribe jobs start within ~1s of enqueue

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, add a new status row for this plan
> in `plans/README.md` (the table currently ends at 019, so add row 023):
> `| 023 | Run Solid Queue in a dedicated worker so jobs start promptly | P3 | S | — | TODO |`
> — unless a reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 58fd6a5..HEAD -- config/deploy.yml config/queue.yml config/puma.rb config/environments/production.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `58fd6a5`, 2026-07-11

## Why this matters

"Snappy" scribe processing depends not only on how fast `ProcessScribeSessionJob`
*runs*, but on how fast it *starts* after the commit that enqueues it. Today the
Solid Queue supervisor runs **inside the web Puma process** (`SOLID_QUEUE_IN_PUMA: true`
in `config/deploy.yml`). That couples job execution to the web dyno's lifecycle:
every deploy or web restart tears down the in-Puma supervisor and interrupts
in-flight job processing. (The `solid_queue` Puma plugin forks separate worker OS
processes, so it does not share the request-serving threads' GVL — the problem is
lifecycle coupling and restart isolation, not thread contention.) Splitting job
execution into a dedicated Kamal `job` role — the split the Rails 8 default config explicitly
recommends "when you start using multiple servers" — gives a process whose only
job is to poll and drain the queue, so the first ASR call happens promptly after
commit. The worker poll interval is already sub-second (0.1s, see Current state),
so this plan is almost entirely a deploy-topology change: move the poller out of
Puma and into its own process, without introducing double-processing.

## Current state

- **Queue adapter is Solid Queue in production**
  (`config/environments/production.rb:53-54`):
  ```ruby
  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
  ```
  Test and dev run jobs synchronously: `config/environments/test.rb:27` sets
  `config.active_job.queue_adapter = :inline`; development leaves the framework
  default (no solid_queue adapter is configured there).

- **The poller currently runs in-Puma.** `config/deploy.yml:36-39` injects the
  env var that turns it on:
  ```yaml
    clear:
      # Run the Solid Queue Supervisor inside the web server's Puma process to do jobs.
      # When you start using multiple servers, you should split out job processing to a dedicated machine.
      SOLID_QUEUE_IN_PUMA: true
  ```
  and `config/puma.rb:36-37` loads the plugin only when that var is set:
  ```ruby
  # Run the Solid Queue supervisor inside of Puma for single-server deployments
  plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
  ```
  So unsetting `SOLID_QUEUE_IN_PUMA` is sufficient to stop Puma from running the
  poller — `config/puma.rb` does not need editing.

- **A dedicated `job` role is scaffolded but commented out**
  (`config/deploy.yml:8-14`):
  ```yaml
  servers:
    web:
      - 192.168.0.1
    # job:
    #   hosts:
    #     - 192.168.0.1
    #   cmd: bin/jobs
  ```
  The server hosts here (`192.168.0.1`, registry `username: your-user`,
  `proxy.host: app.example.com`) are **placeholder scaffold values** — the real
  production infra is supplied by the operator at deploy time / out of this
  committed file. This constrains what this plan can safely commit (see STOP
  conditions).

- **`bin/jobs` is the worker entrypoint** (`bin/jobs`, full file):
  ```ruby
  #!/usr/bin/env ruby

  require_relative "../config/environment"
  require "solid_queue/cli"

  SolidQueue::Cli.start(ARGV)
  ```
  This boots the full Solid Queue supervisor (dispatcher + scheduler + workers),
  reading `config/queue.yml`.

- **Worker poll interval is already sub-second** (`config/queue.yml:1-13`):
  ```yaml
  default: &default
    dispatchers:
      - polling_interval: 1
        batch_size: 500
    workers:
      - queues: "*"
        threads: 3
        processes: <%= ENV.fetch("JOB_CONCURRENCY", 1) %>
        polling_interval: 0.1
  ```
  Job *pickup* latency is governed by the worker `polling_interval: 0.1` (100 ms),
  which is already in the target ~0.1–0.5s band. The dispatcher's `polling_interval: 1`
  only governs scheduled/future-dated jobs, not immediate enqueues, so it does not
  add pickup latency for `perform_later`. **No change to `config/queue.yml` is
  required** for the latency goal; Step 3 only verifies this.

- **Recurring tasks run in the supervisor** (`config/recurring.yml:1-9`):
  ```yaml
  production:
    reservation_sweeper:
      class: Metering::ReservationSweeperJob
      queue: background
      schedule: every 5 minutes
  ```
  `bin/jobs` runs the scheduler, so moving off in-Puma to a dedicated `bin/jobs`
  process keeps `reservation_sweeper` firing — as long as exactly one supervisor
  runs (do not run it in both Puma and the job role).

- **Deploy tooling is Kamal, not a PaaS app spec.** `config/deploy.yml` +
  `.kamal/` are the committed deploy config; there is no `Procfile` (only
  `Procfile.dev`, which lists `web` + `css` for local dev) and no DigitalOcean /
  App Platform app spec in the repo. The container command is fixed in the image
  (`Dockerfile:57` → `CMD ["./bin/thrust", "./bin/rails", "server"]`); Kamal
  overrides it per-role via `cmd:` (that is what the commented `job` role does
  with `cmd: bin/jobs`).

## Commands you will need

| Purpose            | Command                                                              | Expected on success            |
|--------------------|---------------------------------------------------------------------|--------------------------------|
| Bundle install     | `ASDF_RUBY_VERSION=3.4.1 bundle install`                             | exit 0                         |
| Validate deploy.yml | `ASDF_RUBY_VERSION=3.4.1 bin/kamal config` (or `ruby -ryaml -e 'YAML.load_file("config/deploy.yml")'`) | parses without error |
| Boot the worker    | `ASDF_RUBY_VERSION=3.4.1 SOLID_QUEUE_IN_PUMA= bin/jobs`              | supervisor starts, begins polling |
| Full tests         | `ASDF_RUBY_VERSION=3.4.1 bin/rails test`                             | 0 failures                     |
| Lint               | `ASDF_RUBY_VERSION=3.4.1 bin/rubocop`                                | no offenses                    |

(There is no `package.json` in this repo — no JS/frontend build, test, or lint
commands apply.)

## Scope

**In scope** (the only files you should modify):
- `config/deploy.yml` — add the dedicated `job` role and remove the in-Puma
  poller env var.
- `config/queue.yml` — inspect only; edit **only** if Step 3's verification shows
  the worker poll interval is no longer 0.1s.

**Out of scope** (do NOT touch, even though they look related):
- `config/puma.rb` — the `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]`
  guard is left in place intentionally; unsetting the env var disables it, and
  keeping the guard preserves the single-server / dev option. Do not delete it.
- Application job code and the scribe pipeline (`app/jobs/*`,
  `app/services/scribe/*`, `app/services/llm/*`) — this is a deploy-topology
  change only; job behavior must not change.
- `config/recurring.yml`, database config (`config/database.yml`), and the
  queue-database migrations (`db/queue_*`) — unchanged.
- Any non-queue infrastructure.

## Git workflow

- Branch: `advisor/023-dedicated-solid-queue-worker` (or the repo's branch-naming
  convention if one is evident from `git branch -a`).
- One commit for the topology change; message style follows the repo's imperative
  short-subject convention (e.g. from `git log --oneline`: "Scope CORS to /api/*
  for browser scribe clients"). Example subject: "Run Solid Queue in a dedicated
  Kamal job role".
- Do NOT push or open a PR unless the operator instructed it. This change alters
  production job execution — it must be reviewed before it deploys.

## Steps

### Step 0: Discover the current job-execution topology and decide go/no-go

Confirm the facts in "Current state" against the live repo before changing
anything. Run:

```
grep -n "SOLID_QUEUE_IN_PUMA" config/deploy.yml
grep -n "polling_interval" config/queue.yml
grep -n "plugin :solid_queue" config/puma.rb
grep -n "queue_adapter" config/environments/production.rb
```

Interpret the result:

- If `config/deploy.yml` still contains `SOLID_QUEUE_IN_PUMA: true` **and** has no
  active (uncommented) `job:` server role → the poller runs in-Puma; there is no
  dedicated worker. **Proceed** with this plan.
- If a dedicated `job:` role is already active in `config/deploy.yml` (uncommented,
  with `cmd: bin/jobs`) **and** `SOLID_QUEUE_IN_PUMA` is absent/false **and** the
  worker `polling_interval` in `config/queue.yml` is ≤ 0.5 → the desired topology
  already exists. Mark this plan **REJECTED** in `plans/README.md` with the reason
  "dedicated worker already deployed; nothing to do" and STOP.

Record what you found (in-Puma vs dedicated; the exact `polling_interval` values)
in your report.

**Verify**: `grep -c "SOLID_QUEUE_IN_PUMA: true" config/deploy.yml` → `1`
(confirming the in-Puma poller is currently the active topology, i.e. there is
work to do).

### Step 1: Add a dedicated Kamal `job` role running `bin/jobs`

In `config/deploy.yml`, uncomment and populate the `job` role under `servers:`
(currently commented at lines 11–14). Target shape:

```yaml
servers:
  web:
    - 192.168.0.1
  job:
    hosts:
      - 192.168.0.1
    cmd: bin/jobs
```

The `hosts:` value is a **placeholder** (`192.168.0.1`) matching the existing web
scaffold. Do NOT invent a real production IP — leave the placeholder and flag it
for the operator per the STOP conditions. The load-bearing structural change is:
the `job` role exists, and its `cmd:` is `bin/jobs` (overriding the image's
default `rails server` command for that role).

**Verify**: `ruby -ryaml -e 'c=YAML.load_file("config/deploy.yml"); abort("no job role") unless c.dig("servers","job","cmd")=="bin/jobs"; puts "job role cmd ok"'`
→ prints `job role cmd ok` and exits 0.

### Step 2: Stop Puma from running the poller (avoid double-processing)

Remove the `SOLID_QUEUE_IN_PUMA: true` line and its two explanatory comment lines
from `config/deploy.yml:37-39` (inside `env.clear`). With the env var unset in
production, `config/puma.rb:37`'s `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]`
becomes a no-op, so the web Puma no longer starts a supervisor. This is required:
if both the web role (in-Puma) and the new `job` role run supervisors, jobs and
recurring tasks are processed twice.

Do **not** edit `config/puma.rb`. Leave the `env.secret` block and the commented
`JOB_CONCURRENCY` / `WEB_CONCURRENCY` lines intact.

After editing, `env.clear` should no longer mention `SOLID_QUEUE_IN_PUMA`.

**Verify**: `grep -c "SOLID_QUEUE_IN_PUMA" config/deploy.yml` → `0`.

### Step 3: Confirm the worker poll interval is already sub-second

The latency goal (job starts within ~1s of enqueue) is already met by the worker
`polling_interval: 0.1` in `config/queue.yml:9` (100 ms). Do not lower it further
unless the operator asks — 0.1s is already sub-second and lower values add DB poll
load for no user-visible gain. Only if the grep below shows the interval is
**missing or > 0.5** should you set the worker `polling_interval` to `0.1` under
the `workers:` entry (leave the dispatcher's `polling_interval: 1` alone — it only
affects future-dated jobs, not immediate `perform_later`).

**Verify**: `ruby -ryaml -e 'c=YAML.load_file("config/queue.yml"); pi=c.dig("default","workers",0,"polling_interval"); abort("worker poll #{pi} not sub-second") unless pi && pi<=0.5; puts "worker polling_interval=#{pi} ok"'`
→ prints `worker polling_interval=0.1 ok` and exits 0.

### Step 4: Boot the dedicated worker locally to prove `bin/jobs` starts and polls

Confirm the worker command actually boots the supervisor with the in-Puma env var
unset (mirroring the new production state). Run with a timeout so it self-exits:

```
ASDF_RUBY_VERSION=3.4.1 SOLID_QUEUE_IN_PUMA= timeout 20 bin/jobs 2>&1 | tee /tmp/jobs_boot.log; \
  grep -Eiq "SolidQueue.*(started|Starting)|Started Supervisor|Starting Worker" /tmp/jobs_boot.log && echo BOOT_OK
```

Expected: the log shows the Solid Queue supervisor/worker starting up (e.g. a line
naming `SolidQueue` starting a Supervisor/Worker), and the command prints
`BOOT_OK`. `timeout` will terminate the long-running process after 20s — that
termination is expected and not a failure.

This check is **conditional / best-effort**, not a mandatory gate. It requires a
reachable dev database with the Solid Queue tables present (they are defined in
`db/queue_schema.rb`). If `bin/jobs` cannot connect to a database locally (missing
`DB_*` env / no local Postgres), that is an environment gap, not a plan defect and
not a STOP: capture the boot output and **proceed** — staging is the real
verification of the topology.

**Verify (conditional)**: BOOT_OK only if a dev DB with the `solid_queue` tables is
reachable; the command above prints `BOOT_OK`. Otherwise, capture the boot output
and proceed — an unproduced BOOT_OK in a DB-less dev environment is expected and
acceptable.

## Test plan

This is a deploy-configuration change; verification is by inspection plus a local
boot check. There is **no new automated Rails test** — job *behavior* is unchanged,
and the topology (which process runs the supervisor) is not exercised by the
`:inline` test adapter.

- **Config parses**: `ASDF_RUBY_VERSION=3.4.1 bin/kamal config` (if Kamal and its
  credentials are available) or the `ruby -ryaml` loader in Step 1 → no parse
  error and the `job` role is present.
- **No double-processing**: `grep -n "SOLID_QUEUE_IN_PUMA" config/deploy.yml` →
  returns nothing (the in-Puma poller is off), and the `job` role is the only
  supervisor.
- **Worker boots and polls** (manual, Step 4): `bin/jobs` starts the supervisor
  and begins polling with `SOLID_QUEUE_IN_PUMA` unset → prints `BOOT_OK`.
- **Full end-to-end drain** (manual, exercised in staging, not required locally):
  after `bin/kamal deploy`, enqueue a `ProcessScribeSessionJob` via a normal
  scribe commit and confirm from `bin/kamal logs -r job` that the job is claimed
  and runs within ~1s, and that the web logs show no supervisor starting.
- **Optional boot sanity check** (environment-dependent): `config/deploy.yml` is
  Kamal deploy config and is never loaded by the Rails process, so the suite does
  **not** exercise these edits — running it only confirms the app still boots.
  `ASDF_RUBY_VERSION=3.4.1 bin/rails test` is therefore optional and may not run in
  this environment (it needs a test DB, e.g. `DB_NAME_TEST`); if it runs, expect 0
  failures. `ASDF_RUBY_VERSION=3.4.1 bin/rubocop` → no offenses.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `config/deploy.yml` has an active `job` server role whose `cmd` is `bin/jobs`
      (`ruby -ryaml -e 'exit(YAML.load_file("config/deploy.yml").dig("servers","job","cmd")=="bin/jobs" ? 0 : 1)'` exits 0)
- [ ] `grep -c "SOLID_QUEUE_IN_PUMA" config/deploy.yml` returns `0`
- [ ] `config/puma.rb` is unchanged (`git diff --stat 58fd6a5..HEAD -- config/puma.rb` shows no change)
- [ ] The worker `polling_interval` in `config/queue.yml` is ≤ 0.5 (Step 3 verify prints `... ok`)
- [ ] (Conditional, best-effort) `ASDF_RUBY_VERSION=3.4.1 SOLID_QUEUE_IN_PUMA= timeout 20 bin/jobs` boots the supervisor (Step 4 prints `BOOT_OK`) **only if** a dev DB with the `solid_queue` tables is reachable; otherwise the captured boot output is sufficient and this is not a blocker — staging is the real verification
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rubocop` reports no offenses
- [ ] (Optional, environment-dependent) `ASDF_RUBY_VERSION=3.4.1 bin/rails test`
      exits 0 with 0 failures if a test DB (e.g. `DB_NAME_TEST`) is available — this
      is a boot sanity check only; the Kamal deploy config is not loaded by the suite
- [ ] No files outside the in-scope list are modified (`git status`) — carve-out: `plans/README.md` and this plan file are expected to change and are exempt from the in-scope check
- [ ] `plans/README.md` has a new row for plan 023 (the table currently ends at 019): `| 023 | Run Solid Queue in a dedicated worker so jobs start promptly | P3 | S | — | TODO |`
- [ ] The report to the operator names the exact manual action required (fill the
      real `job` host in `config/deploy.yml` and run `bin/kamal deploy`)

## STOP conditions

Stop and report back (do not improvise) if:

- The live `config/deploy.yml` / `config/queue.yml` / `config/puma.rb` /
  `production.rb` do not match the "Current state" excerpts (drift since this plan
  was written).
- **Real production infra values are needed.** The committed `config/deploy.yml`
  uses placeholder hosts (`192.168.0.1`), registry (`username: your-user`), and
  `proxy.host: app.example.com`. Do NOT guess the real production/job host, IP, or
  registry. Make the structural edits (add the `job` role skeleton with the
  existing placeholder host; remove `SOLID_QUEUE_IN_PUMA`), then STOP and hand the
  operator this exact manual step: set the real `servers.job.hosts` value in
  `config/deploy.yml` (a separate machine, or the same host as web if consolidating)
  and run `bin/kamal deploy`. Do not deploy from this plan.
- (Not a STOP) Step 4's boot check not producing `BOOT_OK` because no local
  database/Solid Queue schema is available is **expected and acceptable** — do not
  stop for it. Capture the boot output and proceed; the config edits stand, and the
  drain is verified in staging instead. (Listed here only to be explicit that this
  case is not a STOP condition.)
- Step 0 finds a dedicated worker already deployed (mark REJECTED per Step 0).
- Any verification fails twice after a reasonable fix attempt.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Exactly one supervisor.** After this change the `job` role is the sole Solid
  Queue supervisor. If someone re-adds `SOLID_QUEUE_IN_PUMA: true` (or uncomments
  the puma plugin) while the `job` role is active, jobs and every
  `config/recurring.yml` task (e.g. `reservation_sweeper`) will run twice. A
  reviewer should confirm the in-Puma poller is off whenever a `job` role exists.
- **Recurring tasks moved with the supervisor.** `config/recurring.yml`'s
  `reservation_sweeper` now runs on the `job` host via `bin/jobs`. Confirm it still
  fires after deploy (`bin/kamal logs -r job` should show it every 5 minutes).
- **Poll-interval / DB-load tradeoff.** Worker `polling_interval: 0.1` gives ~100 ms
  pickup latency at the cost of ~10 queue-DB polls/sec per worker process. Lowering
  it further buys little perceptible latency and increases DB load; raising it makes
  scribe jobs feel laggier. If `JOB_CONCURRENCY` is raised, remember poll load scales
  with process count.
- **Billing / infra.** A dedicated `job` role is a separate Kamal-managed container
  (and, if `hosts:` points at a different machine, a separately billable server).
  Consolidating web + job onto one host is possible (point `job.hosts` at the web
  host) but reintroduces the resource contention this plan removes — decide per the
  server's headroom.
- **Design adaptation note (underspecified in the source spec).** The originating
  spec framed the worker as a `Procfile` entry + a DigitalOcean App Platform worker
  component. This repo has neither: production deploys via **Kamal**
  (`config/deploy.yml`, `.kamal/`) with no `Procfile` and no committed PaaS app
  spec. The smallest faithful realization of "a dedicated worker component running
  `bin/jobs`" is therefore the Kamal `job` server role, chosen here. If the deploy
  platform later changes, the equivalent is one worker process running `bin/jobs`
  with the in-Puma poller disabled.
