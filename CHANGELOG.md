# Changelog

All notable changes will be documented here.

## Unreleased

## 0.2.0 - 2026-08-28

- Strengthened web-research routing for recent/latest questions and natural-language permission to use the internet.
- Added current-date and live-internet capability grounding for temporal follow-up questions.
- Added Langflow virtual models to the native Ollama and OpenAI-compatible model APIs.
- Added configurable Langflow workflows, API authentication, stable sessions, and optional Lasagna recall/commit memory integration.
- Added virtual-model discovery and metadata support for Ollama-compatible clients.
- Added a browser-based magazine studio that turns live web research into downloadable PDF editions.
- Added article-page discovery, publisher preview images, grounded long-form editorial passes, source attribution, and safe source-led fallback behavior.
- Added magazine-style covers, contents pages, two-column features, unlimited continuation pages, sequential page numbering, and reporting notes.
- Added tests for structured editorial decoding, article discovery and cleanup, source-led fallback, image metadata, PDF rendering, and long-article pagination.

## 0.1.1 - 2026-08-21

- Added per-query Apple Silicon GPU sampling and persisted benchmark averages.
- Added authenticated cancellation for active generations and server-owned tool runs.
- Added database-backed pagination, search, and state filters for completion and web-tool histories.
- Added expandable request timing waterfalls with linked web-tool activity.
- Added latest-run generation-speed and time-to-first-token regression indicators.
- Added authenticated model preload, keep-alive, expiration, and unload controls.
- Added persistent model-operation progress, duplicate prevention, and residency feedback.
- Added interaction-safe dashboard refreshes and flicker-free active request details.
- Added automatic opening and closing of details for running queries.
- Changed server-owned web-tool injection to relevance-based routing so self-contained prompts remain transparent.

## 0.1.0 - 2026-08-21

- Transparent Ollama and OpenAI-compatible proxy with persistent performance metrics.
- Responsive monitoring and benchmark dashboard.
- Server-owned web search and Markdown-preserving page fetch tools.
- Persistent, request-linked web-tool history.
- Live JSON configuration with authenticated administration.
- Per-query CPU and memory sampling.
- Private-network fetch protection enabled by default.
