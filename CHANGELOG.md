# Changelog

All notable changes will be documented here.

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
