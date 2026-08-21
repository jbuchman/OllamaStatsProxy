#!/bin/sh
set -eu

# Copy this file to run.sh. The local run.sh is ignored by Git.
export OLLAMA_ADMIN_PASSWORD='replace-with-a-long-random-password'
export OLLAMA_WEB_SEARCH_PROVIDER='tavily'
export OLLAMA_WEB_SEARCH_API_KEY='replace-with-your-provider-key'

exec swift run ollama-stats-proxy --host 127.0.0.1
