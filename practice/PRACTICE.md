# Practice environment

A small copy of the target: kind cluster `ahpractice`, namespace `monitoring`.

| component | details |
|---|---|
| Prometheus v3.5.0 | StatefulSet `prometheus`, pod `prometheus-0`, container `prometheus`, PVC `data-prometheus-0` (20Gi) at `/prometheus`, `--storage.tsdb.retention.time=400d`, `--web.enable-admin-api`, scrapes itself |
| Grafana 12.1.1 | Deployment `grafana`, datasource `env2-prometheus` (uid `env2prom`, `prometheusType: Prometheus`), dashboard "Alert state history (backfilled)" in folder "Alert history" |
| env1 (optional) | Grafana 12.0.0 in Docker (compose project `ahpractice`), synthetic rules, source for the export practice |

## URLs and login

| what | URL | login |
|---|---|---|
| Prometheus (env2) | http://127.0.0.1:29190 | none |
| Grafana (env2) | http://127.0.0.1:23101 | `admin` / `labadmin` |
| Dashboard | http://127.0.0.1:23101/d/alert-history-backfill | same |
| env1 Grafana (practice source) | http://127.0.0.1:23100 | `admin` / `labadmin` |

All ports listen on 127.0.0.1 only (kind `extraPortMappings` to NodePorts
30990 and 30301). These are throwaway lab passwords.

## kubectl

The cluster has its own kubeconfig file, so nothing touches other kind clusters
on the host (for example `alert-analyser`):

```bash
cd <repo>
export KUBECONFIG=$PWD/practice/kubeconfig
kubectl -n monitoring get pods,pvc
```

If the file is missing (it is not in git):
`kind export kubeconfig --name ahpractice --kubeconfig practice/kubeconfig`.

## Start, stop

```bash
SKIP_ENV1=1 practice/up.sh   # cluster + Prometheus + Grafana (idempotent)
practice/up.sh               # also env1 Grafana 12.0.0 with seeded history
practice/down.sh             # delete the cluster and env1 (all data gone)
```

## What is loaded now

The real history from the grafana-git-sync repo (2025-12-10 to 2026-10-29,
`source="grafana-git-history"`). See `docs/test-results.md` part 2 for numbers.
In the dashboard set the time range to 2025-12-01 .. 2026-11-01 (the default).

Queries to try in Explore:

```promql
ALERTS_HISTORY{source="grafana-git-history"} == 1
count by (alertname) (ALERTS_HISTORY{alertstate="firing"} == 1)
count(count by (alertname) (ALERTS_HISTORY))
```

Retention: 400d counted from the newest block's max time. Self-scrape keeps the
newest block near "now", so the first imported block (max time 2025-12-30)
is deleted around 2027-02-03, and the oldest data goes from there on.

## Redo the import yourself

From the repo root, with real data under `work/` (ignored by git):

```bash
export KUBECONFIG=$PWD/practice/kubeconfig

# 0. wipe env2 Prometheus (deletes the StatefulSet and PVC, recreates them empty)
practice/reset-env2.sh

# 1. dump from the git history (read only)
python3 tool/gitsync_to_dump.py /path/to/g-sync-test -o work/dump-git.json

# 2. convert, one OpenMetrics file per 486h window
python3 tool/gah2prom.py convert -i work/dump-git.json -o work/om --split 486h \
  --step 1m --source grafana-git-history --deleted-rule-end last-event

# 3. blocks
mkdir -p work/blocks && cd work
ls om/*.om | xargs -P 4 -I{} docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w \
  --entrypoint promtool prom/prometheus:v3.5.0 \
  tsdb create-blocks-from openmetrics --max-block-duration=486h /w/{} /w/blocks
cd ..

# 4. copy under a temp name, then rename inside the pod
for b in work/blocks/01*; do u=$(basename "$b")
  kubectl -n monitoring cp "$b" prometheus-0:/prometheus/$u.tmp-for-creation -c prometheus; done
kubectl -n monitoring exec prometheus-0 -c prometheus -- sh -c \
  'cd /prometheus && for d in *.tmp-for-creation; do mv "$d" "${d%.tmp-for-creation}"; done'
# within a minute: prometheus_tsdb_blocks_loaded = number of blocks

# 5. verify (target: missing 0, unexpected 0, exit 0)
python3 tool/gah2prom.py verify -i work/dump-git.json --prometheus http://127.0.0.1:29190 \
  --source grafana-git-history --deleted-rule-end last-event
```

Disk: step 2 writes about 29 GB of OpenMetrics text (check free disk first); the blocks are about
60 MB. Delete `work/om` afterwards.

Practice ideas: import the same blocks twice and verify again (duplicates are
merged); try the rollback with `delete_series` (runbook "Rollback"); run the
synthetic env1 export (`gah2prom.py export --url http://127.0.0.1:23100 --user admin --password labadmin ...`)
with a different `--source` next to the real data.
