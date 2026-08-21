# Security policy

## Supported versions

Until the first stable release, security fixes are applied to the latest tagged release and the `main` branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature rather than opening a public issue. Include affected versions, reproduction steps, impact, and any suggested mitigation. Do not include working credentials, private prompts, fetched page contents, or other sensitive data.

## Deployment boundary

Ollama Stats Proxy is designed for a trusted workstation or trusted local network. Prefer the default loopback binding. If it is exposed beyond the machine, place it behind an authenticated HTTPS reverse proxy and firewall it appropriately. Admin authentication does not encrypt HTTP traffic.

Web fetching blocks non-public destinations by default. Enabling private-network fetches permits models and direct callers to reach LAN services and should only be done in a trusted environment.

