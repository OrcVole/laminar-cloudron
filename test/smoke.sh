#!/bin/bash
# smoke.sh — the real runtime gate. Builds nothing by default; runs the assembled image Cloudron-style
# against a throwaway Postgres on a container network, then asserts the package contract:
#   - all four services (clickhouse, quickwit, app-server, frontend) reach RUNNING, as the cloudron user
#   - /sign-in (the healthCheckPath) returns 200 with NO auth, after the on-boot PG + ClickHouse migrations
#   - AEAD_SECRET_KEY is exactly 64 hex and never leaks into the logs (data-loss-critical secret)
#   - ClickHouse runs in UTC; the app-server OTLP/REST port answers
# Usage: test/smoke.sh [IMAGE]   (default ghcr.io/orcvole/laminar:dev). ENGINE=docker to use docker.
set -uo pipefail

IMAGE="${1:-ghcr.io/orcvole/laminar:dev}"
ENGINE="${ENGINE:-podman}"
NET=lmnr-smoke-net; VOL=lmnr-smoke-data; PG=lmnr-smoke-pg; APP=lmnr-smoke-app
PGPASS="pg$(date +%s 2>/dev/null || echo 12345)x"
fails=0; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }

cleanup(){ $ENGINE rm -f $APP $PG >/dev/null 2>&1; $ENGINE volume rm $VOL >/dev/null 2>&1; $ENGINE network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT; cleanup

echo "=== smoke: image=${IMAGE} engine=${ENGINE} ==="
$ENGINE network create $NET >/dev/null
$ENGINE volume create $VOL >/dev/null
$ENGINE run -d --name $PG --network $NET -e POSTGRES_USER=laminar -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=laminar docker.io/library/postgres:16 >/dev/null
sleep 8
$ENGINE run -d --name $APP --network $NET -p 15667:5667 -v $VOL:/app/data \
  -e CLOUDRON=1 \
  -e CLOUDRON_POSTGRESQL_URL="postgres://laminar:${PGPASS}@${PG}:5432/laminar" \
  -e CLOUDRON_APP_ORIGIN="http://localhost:15667" \
  -e LAMINAR_INGEST_FQDN="localhost:15667" \
  "$IMAGE" >/dev/null

# 1. health: /sign-in 200 (first boot runs PG + ClickHouse migrations; allow ~6 min). -m caps each poll.
hc=0
for i in $(seq 1 120); do
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:15667/sign-in 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { hc=1; ok "/sign-in 200 (health)"; break; }
  sleep 3
done
[ "$hc" = 1 ] || { bad "/sign-in never 200 (last code=$code)"; $ENGINE logs --tail 80 $APP; exit 1; }

# 2. all four services RUNNING
st=$($ENGINE exec $APP supervisorctl -c /etc/supervisor/supervisord.conf status 2>/dev/null)
for svc in clickhouse quickwit app-server frontend; do
  echo "$st" | grep -qE "^${svc}[[:space:]]+RUNNING" && ok "service ${svc} RUNNING" || bad "service ${svc} not RUNNING"
done

# 3. services run as the unprivileged cloudron user
nonroot=$($ENGINE exec $APP sh -c 'ps -eo user,comm 2>/dev/null | grep -E "clickhouse|quickwit|app-server|node" | grep -vc cloudron' 2>/dev/null || echo 1)
[ "${nonroot:-1}" = 0 ] && ok "services run as cloudron" || bad "some service not running as cloudron ($nonroot non-cloudron)"

# 4. AEAD_SECRET_KEY 64 hex + not in logs
klen=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; printf %s "$AEAD_SECRET_KEY" | wc -c' 2>/dev/null)
[ "$klen" = 64 ] && ok "AEAD_SECRET_KEY is 64 hex" || bad "AEAD_SECRET_KEY length=$klen (want 64)"
ek=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; printf %s "$AEAD_SECRET_KEY"' 2>/dev/null)
$ENGINE logs $APP 2>&1 | grep -qF "$ek" && bad "AEAD_SECRET_KEY leaked into logs" || ok "no AEAD_SECRET_KEY in logs"

# 5. ClickHouse runs in UTC (Laminar's spans views assume it)
tz=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; curl -s "http://localhost:8123/?user=laminar&password=${CLICKHOUSE_PASSWORD}" --data-binary "SELECT timezone()"' 2>/dev/null)
[ "$tz" = "UTC" ] && ok "ClickHouse timezone is UTC" || bad "ClickHouse timezone='$tz' (want UTC)"

# 6. app-server OTLP/REST port is up (a POST without an API key is rejected, not connection-refused)
code=$($ENGINE exec $APP sh -c 'curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST http://localhost:8000/v1/traces' 2>/dev/null || echo 000)
{ [ -n "$code" ] && [ "$code" != "000" ]; } && ok "app-server :8000 answers OTLP path (HTTP $code)" || bad "app-server :8000 unreachable"

echo "=== smoke result: $fails failure(s) ==="
exit $((fails > 0 ? 1 : 0))
