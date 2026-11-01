#!/bin/sh
# apply-simple.sh: put Grafana alert history into a Prometheus pod. No checks, no prompts.
# Steps: dump -> convert -> build blocks with promtool -> copy blocks into the pod.
# Full parameter list and examples: docs/apply-simple.md
set -eu

usage() {
cat <<'EOF'
Usage: apply-simple.sh SOURCE TARGET [OPTIONS]

SOURCE (pick one):
  --git-repo DIR        grafana-git-sync repo with alert-history/ day files
  --grafana-url URL     live Grafana (also needs --token, or --user and --password)
  --dump FILE           dump file made earlier by gitsync_to_dump.py or gah2prom.py export

TARGET (required):
  --namespace NS        Kubernetes namespace of Prometheus
  --pod NAME            Prometheus pod name

Options (defaults in brackets):
  --container NAME      container in the pod                       [prometheus]
  --data-path PATH      Prometheus data directory in the pod       [/prometheus]
  --kubectl BIN         kubectl or oc                              [kubectl]
  --kubeconfig FILE     kubeconfig file                            [current]
  --context NAME        kube context                               [current]
  --promtool PATH       local promtool binary
  --promtool-from-pod   copy promtool out of the Prometheus pod (needs no internet)
  --promtool-pod-path P path of promtool inside the pod            [/bin/promtool]
  --prom-version X.Y.Z  version for the docker image name          [3.5.0]
  --image IMAGE         full promtool image; used only if already on this host
                        (promtool is looked up in this order: --promtool, PATH,
                        local docker image, then copied from the pod)
  --from TIME           start time: RFC3339, epoch ms, or now-30d  [1 = everything]
  --to TIME             end time                                   [now / last row]
  --source-label NAME   value of the source label                  [grafana-history]
  --step DURATION       sample spacing, below Prometheus lookback  [1m]
  --split DURATION      one OpenMetrics file per window            [486h]
  --token T             Grafana service account token
  --user U --password P Grafana basic auth
  --org-id N            Grafana org id
  --insecure            skip TLS check when talking to Grafana
  --tool-dir DIR        folder with gah2prom.py and gitsync_to_dump.py [next to this script]
  --workdir DIR         scratch folder                             [./apply-work]
  --keep-om             keep the OpenMetrics files
  -h, --help            show this help
EOF
}

die() { echo "apply-simple: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

GIT_REPO= GRAFANA_URL= DUMP=
NS= POD= CONTAINER=prometheus DATA_PATH=/prometheus
KUBECTL=kubectl KUBECONFIG_FILE= KCONTEXT=
PROMTOOL= PROM_VERSION=3.5.0 IMAGE= FROM_POD=0 POD_PROMTOOL=/bin/promtool
FROM=1 TO= SOURCE_LABEL=grafana-history STEP=1m SPLIT=486h
TOKEN= GUSER= GPASS= ORG_ID= INSECURE=0
TOOL_DIR=$(cd "$(dirname "$0")" && pwd)
WORKDIR=./apply-work KEEP_OM=0

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --keep-om) KEEP_OM=1; shift; continue ;;
    --insecure) INSECURE=1; shift; continue ;;
    --promtool-from-pod) FROM_POD=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || die "option $1 needs a value (see --help)"
  case $1 in
    --git-repo) GIT_REPO=$2 ;;
    --grafana-url) GRAFANA_URL=$2 ;;
    --dump) DUMP=$2 ;;
    --namespace) NS=$2 ;;
    --pod) POD=$2 ;;
    --container) CONTAINER=$2 ;;
    --data-path) DATA_PATH=$2 ;;
    --kubectl) KUBECTL=$2 ;;
    --kubeconfig) KUBECONFIG_FILE=$2 ;;
    --context) KCONTEXT=$2 ;;
    --promtool) PROMTOOL=$2 ;;
    --promtool-pod-path) POD_PROMTOOL=$2 ;;
    --prom-version) PROM_VERSION=$2 ;;
    --image) IMAGE=$2 ;;
    --from) FROM=$2 ;;
    --to) TO=$2 ;;
    --source-label) SOURCE_LABEL=$2 ;;
    --step) STEP=$2 ;;
    --split) SPLIT=$2 ;;
    --token) TOKEN=$2 ;;
    --user) GUSER=$2 ;;
    --password) GPASS=$2 ;;
    --org-id) ORG_ID=$2 ;;
    --tool-dir) TOOL_DIR=$2 ;;
    --workdir) WORKDIR=$2 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift 2
done

[ -n "$NS" ] && [ -n "$POD" ] || die "--namespace and --pod are required (see --help)"
[ -n "$GIT_REPO$GRAFANA_URL$DUMP" ] || die "give one source: --git-repo, --grafana-url or --dump"
[ -n "$WORKDIR" ] && [ "$WORKDIR" != / ] || die "bad --workdir"

mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)
[ -n "$IMAGE" ] || IMAGE=prom/prometheus:v$PROM_VERSION

K() {
  set -- "$KUBECTL" ${KUBECONFIG_FILE:+--kubeconfig "$KUBECONFIG_FILE"} ${KCONTEXT:+--context "$KCONTEXT"} "$@"
  "$@"
}

# 1. dump
if [ -z "$DUMP" ]; then
  DUMP=$WORKDIR/dump.json
  log "dump -> $DUMP"
  if [ -n "$GIT_REPO" ]; then
    python3 "$TOOL_DIR/gitsync_to_dump.py" "$GIT_REPO" --from "$FROM" ${TO:+--to "$TO"} -o "$DUMP"
  else
    set -- export --url "$GRAFANA_URL" --from "$FROM" --to "${TO:-now}" -o "$DUMP"
    [ -z "$TOKEN" ] || set -- "$@" --token "$TOKEN"
    [ -z "$GUSER" ] || set -- "$@" --user "$GUSER" --password "$GPASS"
    [ -z "$ORG_ID" ] || set -- "$@" --org-id "$ORG_ID"
    [ "$INSECURE" = 0 ] || set -- "$@" --insecure
    python3 "$TOOL_DIR/gah2prom.py" "$@"
  fi
fi

# 2. convert
OM=$WORKDIR/om; BLOCKS=$WORKDIR/blocks
rm -rf "$OM" "$BLOCKS"; mkdir -p "$BLOCKS"
log "convert -> $OM"
python3 "$TOOL_DIR/gah2prom.py" convert -i "$DUMP" -o "$OM" --split "$SPLIT" \
  --step "$STEP" --source "$SOURCE_LABEL" --deleted-rule-end last-event

# 3. blocks. promtool comes from, in order: --promtool, PATH, an image already on this host
# (never pulled), or a copy taken out of the Prometheus pod. Nothing needs the internet.
USE_DOCKER=0
if [ -z "$PROMTOOL" ] && [ "$FROM_POD" = 0 ]; then
  if command -v promtool >/dev/null 2>&1; then
    PROMTOOL=$(command -v promtool)
  elif command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    USE_DOCKER=1
  else
    FROM_POD=1
  fi
fi
if [ "$FROM_POD" = 1 ]; then
  PROMTOOL=$WORKDIR/promtool
  log "copy promtool out of the pod ($POD:$POD_PROMTOOL)"
  K -n "$NS" cp "$POD:$POD_PROMTOOL" "$PROMTOOL" -c "$CONTAINER"
  chmod +x "$PROMTOOL"
  "$PROMTOOL" --version >/dev/null 2>&1 || die "promtool copied from the pod does not run here (different CPU or OS?). Use --promtool PATH"
fi
log "build blocks -> $BLOCKS"
for f in "$OM"/*.om; do
  if [ "$USE_DOCKER" = 0 ]; then
    "$PROMTOOL" tsdb create-blocks-from openmetrics --max-block-duration="$SPLIT" "$f" "$BLOCKS"
  else
    docker run --rm --user "$(id -u):$(id -g)" -v "$WORKDIR":/w --entrypoint promtool "$IMAGE" \
      tsdb create-blocks-from openmetrics --max-block-duration="$SPLIT" "/w/om/$(basename "$f")" /w/blocks
  fi
done
[ "$KEEP_OM" = 1 ] || rm -rf "$OM"

# 4. copy: temp name first, rename inside the pod, so Prometheus never sees a half-copied block
N=0 NAMES=
for b in "$BLOCKS"/*; do
  [ -d "$b" ] || continue
  U=$(basename "$b")
  log "copy $U"
  K -n "$NS" cp "$b" "$POD:$DATA_PATH/$U.tmp-for-creation" -c "$CONTAINER"
  N=$((N + 1)); NAMES="$NAMES $U"
done
[ "$N" -gt 0 ] || die "no blocks were built"
K -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -c \
  "cd '$DATA_PATH' && for u in $NAMES; do mv \"\$u.tmp-for-creation\" \"\$u\"; done"

log "done: $N block(s) copied into $NS/$POD:$DATA_PATH"
log "Prometheus loads them within about a minute. Query: ALERTS_HISTORY{source=\"$SOURCE_LABEL\"} == 1"
