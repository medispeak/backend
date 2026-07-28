# Medispeak Backend

Medispeak: Transforming Patient-Doctor Dialogues Worldwide!

This is the backend API for Medispeak, a tool that provides seamless transcriptions and effortless EMR integration. Our goal is to streamline patient-doctor interactions and automate form filling processes.

## Features

- **Model-agnostic ASR + structuring** — run any model for speech-to-text and any
  model for text-to-form/note, in any combination, including self-hosted models.
  Configuration is runtime, in the database, resolved per page → account → system
  with an ENV fallback.
- **Multi-tenant accounts** — API tokens, model config, usage, quotas, and
  billing scope to a client account. Hashed Bearer tokens (`msk_live_…`,
  reveal-once).
- **Async, metered v2 API** — create a scribe session, upload audio, commit, and
  poll or receive a signed completion webhook. One usage event per provider
  attempt, priced from versioned token/per-minute price tables and settled
  against a credit ledger. Per-account rate limiting.
- **Template management** for various medical forms across EMR systems.

## Tech Stack

- Ruby on Rails
- PostgreSQL

## Getting Started

## Setup

For detailed setup instructions, please refer to our [Setup Documentation](docs/development_setup.md).

## Docker Setup

For a containerized environment, detailed instructions are available in our [Developer Setup Guide with Docker Compose](docs/docker_setup_guide.md). This guide explains how to bring up the services required for running Medispeak via Docker, ensuring an efficient and scalable development workflow.

## Documentation

- [v2 API reference](docs/api/v2.md) — the async, metered public API: auth, session
  lifecycle, endpoints, idempotency, rate limiting, and signed webhooks.
- [Configuration guide](docs/configuration.md) — providers, models, and
  assignments; the page → account → system → ENV resolution; running your own
  model; and mix-and-match setups.
- [Architecture](docs/architecture.md) — the `Llm`/`Scribe`/`Metering` seams and
  the async request lifecycle.
- [Metering & billing](docs/metering-and-billing.md) — usage events, the price
  book, the credit ledger, quotas/rate limits, and the usage endpoint.
- [Design spec](docs/superpowers/specs/2026-06-24-model-agnostic-medispeak-design.md)
  — the model-agnostic design.
