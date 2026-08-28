#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/Tests/Fixtures/mock-ollama.py" & mock_pid=$!
(cd /tmp && exec "$root/.build/debug/ollama-stats-proxy" --port 11437 --upstream http://127.0.0.1:11436 --database /tmp/ollama-stats-proxy-test.sqlite --config /tmp/ollama-stats-proxy-test.json) & proxy_pid=$!
cleanup(){ kill "$proxy_pid" "$mock_pid" 2>/dev/null || true; rm -f /tmp/ollama-stats-proxy-test.sqlite* /tmp/ollama-stats-proxy-test.json /tmp/ollama-lifecycle-response.json; }
trap cleanup EXIT
for _ in {1..30}; do curl -fsS http://127.0.0.1:11437/stats >/dev/null && break; sleep 1; done
curl -fsS http://127.0.0.1:11437/monitor | grep -q 'ollama monitor'
curl -fsS http://127.0.0.1:11437/public/dashboard.js | grep -q 'loadConfiguration'
curl -fsS http://127.0.0.1:11437/version | grep -q '0.2.0'
curl -fsS http://127.0.0.1:11437/healthz | grep -q 'ok'
curl -fsS http://127.0.0.1:11437/api/chat -H 'Content-Type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"Given url(#paint14_radial_13003_106798), append _red using JavaScript"}],"stream":false}' | grep -q 'value.replace'
curl -fsS http://127.0.0.1:11437/api/chat -H 'Content-Type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"Is there a recent Linux distro with up to date pre configured GNUstep and Window Maker? Feel free to use the internet"}],"stream":false}' | grep -q 'Live internet access'
curl -fsS http://127.0.0.1:11437/api/chat -H 'Content-Type: application/json' -d '{"model":"mock","messages":[{"role":"user","content":"Not only do you have access to the internet, but you are confused about the current date (Aug 21, 2026)"}],"stream":false}' | grep -q 'current date was supplied'

curl -fsS -X PUT http://127.0.0.1:11437/config -H 'Content-Type: application/json' -d '{"webSearchProvider":null,"webSearchAPIKey":null,"clearWebSearchAPIKey":false,"webSearchURL":null,"webFetchMaxMB":8,"webFetchMaxCharacters":50000,"webFetchEnabled":false,"webFetchAllowPrivateNetworks":false,"serverToolsEnabled":true,"serverToolRounds":4,"adminPassword":null}' | grep -q '"webFetchEnabled" : false'
test "$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:11437/tools/web/fetch?url=http://127.0.0.1:11436/api/version')" = 403
curl -fsS -X PUT http://127.0.0.1:11437/config -H 'Content-Type: application/json' -d '{"webSearchProvider":null,"webSearchAPIKey":null,"clearWebSearchAPIKey":false,"webSearchURL":null,"webFetchMaxMB":8,"webFetchMaxCharacters":50000,"webFetchEnabled":true,"webFetchAllowPrivateNetworks":false,"serverToolsEnabled":true,"serverToolRounds":4,"adminPassword":null}' >/dev/null
test "$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:11437/tools/web/fetch?url=http://127.0.0.1:11436/api/version')" = 403
curl -fsS -X PUT http://127.0.0.1:11437/config -H 'Content-Type: application/json' -d '{"webSearchProvider":null,"webSearchAPIKey":null,"clearWebSearchAPIKey":false,"webSearchURL":null,"webFetchMaxMB":8,"webFetchMaxCharacters":50000,"webFetchEnabled":true,"webFetchAllowPrivateNetworks":true,"serverToolsEnabled":true,"serverToolRounds":4,"adminPassword":null}' >/dev/null
curl -fsS 'http://127.0.0.1:11437/tools/web/fetch?url=http://127.0.0.1:11436/api/version' | grep -q 'test'
curl -fsS 'http://127.0.0.1:11437/tools/web/fetch?url=http://127.0.0.1:11436/api/version' >/dev/null
curl -fsS 'http://127.0.0.1:11437/web-tools/page?page=2&pageSize=1' | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["page"]==2 and p["pageSize"]==1 and p["totalItems"]>=2 and p["totalPages"]>=2 and len(p["items"])==1'
curl -fsS http://127.0.0.1:11437/api/generate -H 'Content-Type: application/json' -H 'X-Ollama-Benchmark-Label: integration' -d '{"model":"mock","prompt":"not stored","stream":true}' | grep -q '"done": true'
sleep 1
stats="$(curl -fsS http://127.0.0.1:11437/stats)"
python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["recentRequests"][0]; assert r["outputTokens"]==2 and r["promptTokens"]==4 and r["benchmarkLabel"]=="integration"' <<<"$stats"

# Start a deliberately slow stream, discover its live request ID, and cancel it
# through the same authenticated endpoint used by the dashboard.
curl -sS http://127.0.0.1:11437/api/generate -H 'Content-Type: application/json' -d '{"model":"mock-slow","prompt":"slow","stream":true}' >/dev/null & slow_curl_pid=$!
slow_id=""
for _ in {1..30}; do
  slow_id="$(curl -fsS http://127.0.0.1:11437/stats | python3 -c 'import json,sys; print(next((r["id"] for r in json.load(sys.stdin)["recentRequests"] if r["model"]=="mock-slow" and r.get("endedAt") is None), ""))')"
  test -n "$slow_id" && break
  sleep .1
done
test -n "$slow_id"
curl -fsS -X POST "http://127.0.0.1:11437/requests/$slow_id/cancel" | grep -q 'cancelling'
wait "$slow_curl_pid" || true
sleep .2
curl -fsS http://127.0.0.1:11437/stats | python3 -c 'import json,sys; r=next(r for r in json.load(sys.stdin)["recentRequests"] if r["model"]=="mock-slow"); assert r["state"]=="cancelled" and r["error"]=="cancelled by administrator"'
curl -fsS 'http://127.0.0.1:11437/requests?page=2&pageSize=1' | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["page"]==2 and p["pageSize"]==1 and p["totalItems"]>=2 and p["totalPages"]>=2 and len(p["items"])==1'
curl -fsS 'http://127.0.0.1:11437/requests?page=1&pageSize=10&q=mock-slow&state=cancelled' | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["totalItems"]==1 and p["items"][0]["model"]=="mock-slow"'
curl -fsS "http://127.0.0.1:11437/requests/$slow_id" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["request"]["id"] and isinstance(d["webTools"], list)'
curl -fsS 'http://127.0.0.1:11437/web-tools/page?page=1&pageSize=10&q=api%2Fversion&state=done' | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["totalItems"]>=2 and all(r["state"]=="done" for r in p["items"])'
curl -fsS -X POST http://127.0.0.1:11437/models/lifecycle -H 'Content-Type: application/json' -d '{"model":"mock","keepAlive":"-1"}' >/tmp/ollama-lifecycle-response.json & lifecycle_pid=$!
sleep .1
test "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:11437/models/lifecycle -H 'Content-Type: application/json' -d '{"model":"mock","keepAlive":"-1"}')" = 409
wait "$lifecycle_pid"
grep -q 'applied' /tmp/ollama-lifecycle-response.json
curl -fsS http://127.0.0.1:11437/stats | python3 -c 'import json,sys; m=next(m for m in json.load(sys.stdin)["loadedModels"] if m["name"]=="mock"); assert m["expiresAt"].startswith("9999-")'
echo "integration test passed"
