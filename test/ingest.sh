#!/bin/bash
# test/ingest.sh — OTLP/HTTP load generator for the backup-under-load gate (ADR 0007).
#
# Drives continuous LLM-shaped span ingestion at the public ingest FQDN so a `cloudron backup create` runs
# while ClickHouse is actively writing + merging (the torn-copy race the gate must survive). The spans carry
# gen_ai.* + lmnr.span.type=LLM attributes so they populate default.spans AND the _v0 analytics views — the
# post-restore view-aggregate check (gate criterion #3) needs rows in the views, not just the base table.
#
# Usage:
#   API_KEY=<project ingest key> ./test/ingest.sh                         # continuous until killed
#   API_KEY=<key> DURATION=60 ./test/ingest.sh                            # ~60s then stop
#   API_KEY=<key> SPANS_PER_BATCH=100 PAUSE=0.1 ./test/ingest.sh          # tune volume/rate
#   API_KEY=<key> COUNT=1 ./test/ingest.sh                                # one batch (smoke a single payload)
#
# Env: INGEST_URL (default https://laminar-ingest.example.com — set to YOUR ingest FQDN), SPANS_PER_BATCH (50), DURATION secs (0=forever),
#      COUNT batches (0=unbounded), PAUSE secs between batches (0).
set -uo pipefail
: "${API_KEY:?set API_KEY to the project ingestion key}"
export INGEST_URL="${INGEST_URL:-https://laminar-ingest.example.com}"
export SPANS_PER_BATCH="${SPANS_PER_BATCH:-50}"
export DURATION="${DURATION:-0}"
export COUNT="${COUNT:-0}"
export PAUSE="${PAUSE:-0}"
export API_KEY

python3 - <<'PY'
import os, time, json, secrets, urllib.request, urllib.error

url   = os.environ["INGEST_URL"].rstrip("/") + "/v1/traces"
key   = os.environ["API_KEY"]
spb   = int(os.environ["SPANS_PER_BATCH"])
dur   = float(os.environ["DURATION"])
maxb  = int(os.environ["COUNT"])
pause = float(os.environ["PAUSE"])
models = ["gpt-4o", "claude-opus-4-8", "gpt-4o-mini", "claude-haiku-4-5"]

def span(i):
    now = time.time_ns()
    return {
        "traceId": secrets.token_hex(16), "spanId": secrets.token_hex(8),
        "name": "llm.chat", "kind": 1,
        "startTimeUnixNano": str(now - 100_000_000), "endTimeUnixNano": str(now),
        "attributes": [
            {"key": "lmnr.span.type",            "value": {"stringValue": "LLM"}},
            {"key": "gen_ai.system",             "value": {"stringValue": "openai"}},
            {"key": "gen_ai.request.model",      "value": {"stringValue": models[i % len(models)]}},
            {"key": "gen_ai.usage.input_tokens", "value": {"intValue": str(100 + i % 50)}},
            {"key": "gen_ai.usage.output_tokens","value": {"intValue": str(20 + i % 30)}},
        ],
        "status": {},
    }

def payload():
    return json.dumps({"resourceSpans": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "laminar-gate-load"}}]},
        "scopeSpans": [{"scope": {"name": "laminar-gate"}, "spans": [span(i) for i in range(spb)]}],
    }]}).encode()

hdr = {"Content-Type": "application/json", "Authorization": "Bearer " + key}
start = last = time.monotonic(); sent = ok = batches = 0; codes = {}; shown = False
while True:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=payload(), headers=hdr, method="POST"), timeout=10) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
        if not shown:
            try: print("  first non-2xx body:", e.read().decode("utf-8","replace")[:400], flush=True)
            except Exception: pass
            shown = True
    except Exception as e:
        code = "ERR:" + type(e).__name__
    codes[code] = codes.get(code, 0) + 1
    batches += 1; sent += spb
    if code == 200: ok += spb
    if time.monotonic() - last >= 3:
        print(f"  sent={sent} ok={ok} batches={batches} codes={codes}", flush=True); last = time.monotonic()
    if maxb and batches >= maxb: break
    if dur and (time.monotonic() - start) >= dur: break
    if pause: time.sleep(pause)
print(f"DONE sent={sent} ok={ok} batches={batches} codes={codes}", flush=True)
PY
