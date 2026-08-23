---
name: Bug report
about: Report something that is broken or behaving unexpectedly
title: "[Bug] "
labels: bug
assignees: ''
---

> [!WARNING]
> **Do not paste PHI, patient data, real API tokens, or production credentials
> into this issue.** Issues are public and permanent. Redact transcripts, audio,
> lab reports, patient identifiers, `msk_live_…` tokens, provider API keys,
> account ids, and webhook secrets before posting. Reproduce with synthetic data
> wherever you can.
>
> Think you've found a security vulnerability? Close this and follow
> [SECURITY.md](https://github.com/medispeak/backend/blob/main/SECURITY.md)
> instead — do not file it publicly.

## What happened

<!-- The actual behaviour, in a sentence or two. -->

## What you expected

<!-- What should have happened instead. -->

## Steps to reproduce

1.
2.
3.

<!--
For API issues, include the request (method, path, headers with secrets
redacted, body) and the response status and body. `curl` with `Authorization:
Bearer msk_live_REDACTED` is ideal.
-->

## Environment

- Medispeak Backend commit / branch:
- Ruby version (`ruby -v`):
- PostgreSQL version:
- How it's running: local (`bin/dev`) / Docker Compose / self-hosted / other
- Modality involved: audio scribe / document OCR / n/a
- Model providers configured (kind and model id, no keys):
- Browser and OS, if it's a UI or recording issue:

## Logs and errors

<!--
Relevant log lines, stack traces, or job output. Scrub PHI and credentials.
Wrap in a code fence.
-->

```
paste here
```

## Additional context

<!-- Anything else: when it started, whether it's intermittent, workarounds. -->
