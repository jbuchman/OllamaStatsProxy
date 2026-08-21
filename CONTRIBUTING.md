# Contributing

Bug reports and focused pull requests are welcome.

Before submitting a change:

```sh
node --check Sources/OllamaStatsProxy/Public/dashboard.js
swift build
swift test
bash Scripts/integration-test.sh
```

Never commit API keys, passwords, live configuration files, SQLite databases, exported request history, or fetched content. Use `run.example.sh` and `ollama-stats-proxy.example.json` when documenting configuration.

For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

