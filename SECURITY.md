# Security Policy

Medispeak processes protected health information (PHI) and runs multi-tenant
billing. We take reports seriously and we would much rather hear from you than
read about it later. Thank you for taking the time.

## Supported versions

Medispeak Backend is both an open-source project and the code behind a hosted
service. There are no long-lived release branches: **security fixes land on
`main`**, and the hosted service is deployed from `main`.

If you run your own deployment, track `main`. A fix backported to an older
checkout is your responsibility, and we can't support forks that have diverged.

## Reporting a vulnerability

**Please do not open a public GitHub issue, pull request, or discussion for a
security problem.**

Preferred: use GitHub's private vulnerability reporting — go to the
[**Security** tab](https://github.com/medispeak/backend/security) of this
repository and click **"Report a vulnerability"**. This gives us a private
thread with you and keeps the details out of public view until a fix ships.

Fallback, if you can't use GitHub:

<!-- TODO: replace with the real security contact address before publicising this file. -->
Email **security@medispeak.example**.

Please include, as far as you have it:

- What the issue is and what an attacker gains from it.
- Precise reproduction steps, ideally against a local checkout or your own test
  tenant, with the request/response pairs or a minimal proof of concept.
- The affected endpoints, services, or files, and the commit SHA you tested.
- Any thoughts on severity, blast radius, and remediation.

Redact PHI and real credentials from anything you send us. Synthetic data is
always sufficient to demonstrate a bug.

### What to expect

- **Acknowledgement within 72 hours** of your report.
- An initial assessment — severity, whether we can reproduce it, and a rough
  remediation timeline — shortly after that.
- Progress updates as we work the fix, and a note when it ships.
- Credit in the release notes and the advisory if you'd like it; tell us the
  name or handle you want used, or say if you'd rather stay anonymous.

**Please keep the report private until a fix has shipped** and we've agreed on a
disclosure date. If you don't hear from us within 72 hours, follow up — the
silence is a failure on our side, not a signal to publish.

## Scope

This service stores and moves PHI across tenant boundaries and meters real
money. The following are explicitly **in scope and high priority**:

- **Tenant isolation** — any path that lets one account read, write, or infer
  the existence of another account's sessions, transcripts, documents,
  templates, pages, users, or configuration. This includes the tenancy tree
  (org → program → facility) and the model-assignment cascade.
- **PHI leakage** — patient data reaching somewhere it shouldn't: logs,
  exception payloads and error messages, webhook bodies (which are deliberately
  PHI-light), analytics, cached or unsigned storage URLs, admin surfaces, or
  responses to an unauthorized caller.
- **Authentication and token bypass** — forging or replaying API tokens
  (`msk_live_…`), signed session tokens, or webhook signatures; privilege
  escalation between roles; flaws in the admin "view as user" impersonation
  path; session fixation or Devise-related auth weaknesses.
- **SSRF in webhook delivery** — abusing customer-supplied `callback_url`s (or
  any other customer-supplied URL, including self-hosted or custom provider
  `base_url` configuration) to reach internal networks, cloud metadata
  endpoints, or localhost services.
- **Metering and billing integrity** — anything that lets a tenant consume
  provider capacity without a usage event, bypass credit holds, quotas, usage
  limits, or rate limiting, replay or forge dedupe keys, tamper with the price
  book or the credit ledger, or bill usage to another account.

Also in scope, as usual: injection (SQL, command, template), insecure
deserialization, XSS and CSRF in the Rails UI and admin panel, unsafe file
upload and content-type handling, decompression and parser bombs in the document
pipeline, and secrets exposure.

Out of scope: findings from automated scanners with no demonstrated impact,
missing hardening headers or best-practice defaults with no exploit path, rate
limiting on unauthenticated marketing pages, social engineering, physical
attacks, and vulnerabilities in third-party services we merely integrate with
(report those to the vendor).

## Please do not

- **Do not test against production or any hosted Medispeak environment.** Use a
  local checkout; `docs/development_setup.md` and `docs/docker_setup_guide.md`
  will get you one in minutes.
- **Do not access, modify, download, or retain another tenant's data.** If you
  stumble into someone else's data while investigating, stop, don't save it, and
  tell us immediately in the report.
- **Do not run denial-of-service, load, stress, or resource-exhaustion tests**
  against any environment you don't own.
- Do not use automated scanners against hosted environments.
- Do not attempt phishing, social engineering, or physical access against
  Medispeak staff, contributors, or users.
- Do not exfiltrate data, plant backdoors, or degrade service as part of
  demonstrating an issue — a proof of concept should be the minimum that proves
  the point.

Research conducted in good faith and within this policy is welcome, and we won't
pursue action over it.
