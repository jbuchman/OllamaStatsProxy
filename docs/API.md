# HTTP API

Dates use ISO 8601 and public durations use seconds.

## `GET /stats`

Returns live token totals, recent requests, Ollama status, system/process measurements, Apple Silicon GPU measurements, loaded models, and recent web-tool resource activity. `webTools` summarizes search/fetch counts, received bytes, caller (`llm` or `endpoint`), requested query or URL, latency, result count, and errors. Page content and search-result snippets are not retained.

Nullable measurements are `null` when Ollama or macOS does not report them. Active token rates use a rolling two-second window; completed native Ollama requests use `eval_duration` when present.

Each query record also includes `resourceSampleCount`, `averageCPUPercent`, and `averageMemoryUsedBytes`. CPU and used system memory are sampled once per second while a completion is active and persisted with the request.

## Health and version

`GET /healthz` returns `200` with `{"status":"ok"}` when Ollama is reachable and `503` with a degraded status otherwise. `GET /version` returns the proxy name and semantic version.

## `GET /benchmarks`

Returns completed, successful requests grouped by model:

```json
[{
  "model": "llama3.2",
  "runs": 5,
  "averageOutputTokensPerSecond": 42.2,
  "averagePromptTokensPerSecond": 318.4,
  "averageTimeToFirstTokenSeconds": 0.41,
  "averageTotalDurationSeconds": 5.08,
  "averageCPUPercent": 72.4,
  "averageMemoryUsedBytes": 48318382080
}]
```

## Exports

`GET /export.json` returns all stored request records. `GET /export.csv` returns equivalent spreadsheet-friendly data.

## `GET /web-tools`

Returns every persisted web-tool invocation in chronological order. LLM-originated calls include a nullable `requestID` that links to the corresponding record from `GET /export.json`; direct endpoint calls have a null `requestID`. Resources, timing, result/byte counts, and errors are stored, but fetched page contents and search-result snippets are not.

## Configuration

`GET /admin/session` reports whether a password is configured and whether the current browser session is authenticated. `POST /admin/login` accepts a password and issues an `HttpOnly; SameSite=Strict` session cookie; `POST /admin/logout` invalidates it.

Authenticated `GET /config` returns editable web-tool settings with the API key redacted. Authenticated `PUT /config` persists and immediately applies updated settings to new requests; `webFetchEnabled` independently controls direct and model-owned URL fetching. Send a non-empty `webSearchAPIKey` to replace the key, `clearWebSearchAPIKey: true` to remove it, or `adminPassword` to replace the administration password. In-flight requests retain their starting configuration snapshot. `DELETE /history` also requires authentication when a password is configured.

`webFetchAllowPrivateNetworks` defaults to false. With the default, fetches and redirect targets resolving to loopback, private, link-local, multicast, and other non-public ranges are rejected. Enable it only when models are intentionally allowed to access LAN services.

## Retention

`DELETE /history?olderThanDays=N` deletes records older than `N` days and returns `deleted` and `olderThan`. With no positive value, all existing records are deleted. Active generations are not interrupted.

## Benchmark labels

Send `X-Ollama-Benchmark-Label` with a proxied generation request to persist a label alongside its performance metadata.
