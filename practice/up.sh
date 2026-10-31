#!/usr/bin/env bash
# Practice environment: create (or re-check) env1 + env2 and seed env1 alert state history.
# Idempotent: safe to run again; it never touches env2 Prometheus data and seeds old history once.
# SKIP_ENV1=1 ./up.sh  -> only env2 (kind cluster, Prometheus, Grafana with the history dashboard).
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd)
KIND=${KIND:-$(command -v kind || echo "$HOME/.local/bin/kind")}
CLUSTER=ahpractice
export KUBECONFIG="$P/kubeconfig"
ENV1=http://127.0.0.1:23100
AUTH=admin:labadmin
MIN_ANN=${MIN_ANN:-150}
SHIFT_WINDOW_MIN=${SHIFT_WINDOW_MIN:-10}
G1IMG=grafana/grafana:12.0.0

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
ann_count() {  # alert annotations, optional "&from=..&to=.." suffix
  curl -sf -u "$AUTH" "$ENV1/api/annotations?type=alert&limit=100000${1:-}" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
}
wait_env1() {
  for _ in $(seq 1 60); do curl -sf "$ENV1/api/health" >/dev/null && return 0; sleep 2; done
  echo "env1 Grafana not healthy" >&2; exit 1
}

# ---- images (promtool for runbook step 3 lives in prom/prometheus) ----
for img in prom/prometheus:v3.5.0 grafana/grafana:12.1.1 $G1IMG; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
done

# ---- env1 ----
if [ -z "${SKIP_ENV1:-}" ]; then
  log "env1: docker compose up (project ahpractice)"
  docker compose -f "$P/docker-compose.yml" up -d
  wait_env1
fi

# ---- env2 ----
if ! "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "env2: creating kind cluster $CLUSTER"
  "$KIND" create cluster --config "$P/kind-config.yaml" --kubeconfig "$KUBECONFIG" --wait 120s
else
  "$KIND" export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
fi
log "env2: loading images into kind"
# "kind load docker-image" fails on this host (Docker containerd image store, multi-platform
# images: "content digest ... not found"), so import a single-platform save directly.
for img in prom/prometheus:v3.5.0 grafana/grafana:12.1.1; do
  if ! docker exec "$CLUSTER-control-plane" crictl images | grep -Eq "^docker.io/${img%%:*} +${img##*:} "; then
    docker save --platform linux/amd64 "$img"       | docker exec -i "$CLUSTER-control-plane" ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - >/dev/null
  fi
done
kubectl apply -f "$P/k8s/00-namespace.yaml"
kubectl -n monitoring create configmap grafana-dashboards \
  --from-file=alert-history.json="$P/grafana/alert-history-dashboard.json" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$P/k8s/"
kubectl -n monitoring rollout status statefulset/prometheus --timeout=180s
kubectl -n monitoring rollout status deployment/grafana --timeout=180s

[ -n "${SKIP_ENV1:-}" ] && { log "done (env2 only). export KUBECONFIG=$KUBECONFIG"; exit 0; }

# ---- seed env1 history ----
n=$(ann_count)
log "env1: $n alert annotations so far, waiting for >= $MIN_ANN"
while [ "$n" -lt "$MIN_ANN" ]; do sleep 30; n=$(ann_count); log "env1: $n"; done

old_to=$(( ($(date +%s) - 5*3600) * 1000 ))
if [ "$(ann_count "&to=$old_to")" -eq 0 ]; then
  log "env1: copying the first ${SHIFT_WINDOW_MIN} min of history to -6h and -30h (one-time)"
  tmp=$(mktemp -d)
  docker compose -f "$P/docker-compose.yml" stop env1-grafana
  docker run --rm -u 0 -v ahpractice_env1-data:/d -v "$tmp":/s --entrypoint sh $G1IMG \
    -c "cp /d/grafana.db /s/grafana.db && chmod 666 /s/grafana.db"
  python3 "$P/../lab/shift_old_annotations.py" "$tmp/grafana.db" "$SHIFT_WINDOW_MIN" 6 30
  docker run --rm -u 0 -v ahpractice_env1-data:/d -v "$tmp":/s --entrypoint sh $G1IMG \
    -c "cp /s/grafana.db /d/grafana.db && chown 472:0 /d/grafana.db && rm -f /d/grafana.db-journal"
  rm -rf "$tmp"
  docker compose -f "$P/docker-compose.yml" start env1-grafana
  wait_env1
else
  log "env1: old (shifted) history already present, not shifting again"
fi
log "env1: $(ann_count) alert annotations total"
log "done. export KUBECONFIG=$KUBECONFIG"
