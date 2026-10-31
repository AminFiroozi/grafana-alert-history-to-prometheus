#!/usr/bin/env bash
# Lab helper: OpenMetrics file -> TSDB blocks (promtool in the Prometheus image) -> copy into
# the running env2 Prometheus container, fix ownership, wait for the 1-minute block reload.
# Usage: backfill.sh <file.om> <blocks-out-dir> [container]
set -euo pipefail
OM=$(readlink -f "$1"); OUT=$(readlink -f -m "$2"); CTR=${3:-ahlab-env2-prometheus-1}
IMG=prom/prometheus:v3.5.0
mkdir -p "$OUT"
docker run --rm --user "$(id -u):$(id -g)" -v "$(dirname "$OM")":/in:ro -v "$OUT":/out \
  --entrypoint promtool "$IMG" tsdb create-blocks-from openmetrics "/in/$(basename "$OM")" /out
before=$(docker exec "$CTR" sh -c 'ls -d /prometheus/01* 2>/dev/null | wc -l')
for b in "$OUT"/01*; do docker cp "$b" "$CTR:/prometheus/"; done
docker exec -u 0 "$CTR" chown -R nobody:nobody /prometheus
expect=$((before + $(ls -d "$OUT"/01* | wc -l)))
echo "blocks on disk before=$before, copied=$(ls -d "$OUT"/01* | wc -l)"
# Prometheus reloads blocks from disk every minute (tsdb/db.go run loop), no restart needed.
for i in $(seq 1 30); do
  loaded=$(curl -s localhost:29090/api/v1/query --data-urlencode 'query=prometheus_tsdb_blocks_loaded' | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["result"][0]["value"][1])')
  echo "t+$((i*5))s prometheus_tsdb_blocks_loaded=$loaded"
  [ "$loaded" -ge 1 ] && [ "$(docker exec "$CTR" sh -c 'ls -d /prometheus/01* | wc -l')" -le "$loaded" ] && break
  sleep 5
done
