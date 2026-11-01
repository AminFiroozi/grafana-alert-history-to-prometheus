# apply-simple.sh

`tool/apply-simple.sh` is the short version of the migration. It does four things in order and
nothing else:

1. **dump**: reads the alert history from your source into one dump file
2. **convert**: turns the dump into OpenMetrics text files
3. **blocks**: builds TSDB blocks with `promtool`
4. **copy**: copies the blocks into the Prometheus pod (temporary name first, then renamed inside
   the pod, so Prometheus never sees a half-copied block)

It does **no checks and asks no questions**: it does not read Prometheus's version or retention,
does not check disk space, does not ask for confirmation, and does not verify the result. Run the
checks from `README.md` yourself before, and `gah2prom.py verify` after. For the version with
checks, plan mode, rollback and undo, use `tool/migrate.sh`.

It is plain `sh` (tested with `dash`). It installs and downloads nothing and **works with no
internet**: the Python tools use only the standard library, and `promtool` is found in this order:
`--promtool PATH`, then `promtool` in `PATH`, then a Docker image that is **already on the host**
(it is never pulled), then a copy taken out of the Prometheus pod itself (the Prometheus image ships
`/bin/promtool`). It needs `python3` and `kubectl` (or `oc`).
Keep the script in the same folder as `gah2prom.py` and `gitsync_to_dump.py`, or point to them with
`--tool-dir`.

## Parameters

One source is required, plus `--namespace` and `--pod`. Everything else has a default.

### Source (pick one)

| Option | Meaning |
|---|---|
| `--git-repo DIR` | A grafana-git-sync repo that contains `alert-history/YYYY/MM/YYYY-MM-DD.jsonl` |
| `--grafana-url URL` | A live Grafana. Also give `--token`, or `--user` and `--password` |
| `--dump FILE` | A dump file you made earlier. Skips the first step |

### Target (required)

| Option | Meaning |
|---|---|
| `--namespace NS` | Kubernetes namespace of Prometheus |
| `--pod NAME` | Prometheus pod name |

### Options

| Option | Default | Meaning |
|---|---|---|
| `--container NAME` | `prometheus` | Container inside the pod |
| `--data-path PATH` | `/prometheus` | Prometheus data directory in the pod (`storage.tsdb.path`) |
| `--kubectl BIN` | `kubectl` | Use `oc` on OpenShift |
| `--kubeconfig FILE` | current | Kubeconfig file |
| `--context NAME` | current | Kube context |
| `--promtool PATH` | none | Local `promtool` binary |
| `--promtool-from-pod` | off | Copy `promtool` out of the Prometheus pod and use it. Needs no internet |
| `--promtool-pod-path P` | `/bin/promtool` | Where `promtool` is inside the pod |
| `--prom-version X.Y.Z` | `3.5.0` | Prometheus version. Names the Docker image `prom/prometheus:vX.Y.Z` |
| `--image IMAGE` | none | Full image name. Used only if it is already on the host. Overrides `--prom-version` |
| `--from TIME` | `1` (everything) | Start: RFC3339 (`2026-09-01T00:00:00Z`), epoch ms, or `now-30d` |
| `--to TIME` | now | End time |
| `--source-label NAME` | `grafana-history` | Value of the `source` label on every series |
| `--step DURATION` | `1m` | Sample spacing inside a period. Keep it below Prometheus's lookback delta (default 5m) |
| `--split DURATION` | `486h` | Window per OpenMetrics file and the maximum block length |
| `--token T` | none | Grafana service account token |
| `--user U --password P` | none | Grafana basic auth |
| `--org-id N` | default org | Grafana organisation |
| `--insecure` | off | Skip the TLS check when talking to Grafana |
| `--tool-dir DIR` | next to the script | Folder with the Python tools |
| `--workdir DIR` | `./apply-work` | Scratch folder for the dump, text files and blocks |
| `--keep-om` | off | Keep the OpenMetrics files (they are large, about 29 GB for 11 months) |
| `-h`, `--help` | | Print the usage |

## Examples

**1. Git history into the practice cluster** (this repo's practice environment):

```bash
export KUBECONFIG=$PWD/practice/kubeconfig
tool/apply-simple.sh \
  --git-repo /home/amin/workspace/SRE/grafana-git-sync/g-sync-test \
  --from 2026-10-20T00:00:00Z \
  --namespace monitoring --pod prometheus-0
```

**2. Live Grafana into production, with a token, no internet:**

```bash
tool/apply-simple.sh \
  --grafana-url https://grafana.example.internal --token "$GRAFANA_TOKEN" \
  --from 2026-09-01T00:00:00Z \
  --namespace monitoring --pod prometheus-k8s-0 --container prometheus \
  --data-path /prometheus \
  --promtool-from-pod \
  --kubeconfig ~/.kube/prod --context prod \
  --source-label grafana-env1 --workdir /data/migrate
```

**3. A local promtool and a dump you made earlier:**

```bash
tool/apply-simple.sh --dump /data/migrate/dump.json \
  --promtool /usr/local/bin/promtool \
  --namespace monitoring --pod prometheus-0 --kubectl oc
```

**4. High availability, two replicas.** The script copies into one pod per run. Run it again for
the second one with the same `--dump`, so both get identical blocks:

```bash
tool/apply-simple.sh --git-repo "$REPO" --namespace monitoring --pod prometheus-0 --workdir /data/m0
tool/apply-simple.sh --dump /data/m0/dump.json --namespace monitoring --pod prometheus-1 --workdir /data/m1
```

## After it runs

The script prints `done: N block(s) copied`. Prometheus finds new blocks on its next one-minute
scan of the data directory. Then check (`ALERTS_HISTORY` series end with a 0 sample, so always keep
`== 1`):

```promql
count(count by (alertname) (ALERTS_HISTORY{source="grafana-history"}))
ALERTS_HISTORY{source="grafana-history"} == 1
```

To verify the import exactly, use the dump the script left in the work folder:

```bash
python3 tool/gah2prom.py verify -i apply-work/dump.json --prometheus http://<prometheus> \
  --source grafana-history --deleted-rule-end last-event
```

Pass is `missing_in_prometheus: 0` and `unexpected_in_prometheus: 0`.

## Things this script does not protect you from

- Importing data older than Prometheus's retention (Prometheus deletes it).
- Running out of disk, locally (the text files) or in the pod (the blocks).
- A `--step` that is not below Prometheus's lookback delta.
- Importing the same data twice with a different `--source-label`. That creates a second copy of
  every series.
- A promtool version that does not match Prometheus's. `--promtool-from-pod` avoids this, because the
  copy comes from the same image. It fails with a clear message if the host has a different CPU or OS
  than the pod.
- A pod whose image has no `tar` (`kubectl cp` needs it).

## Tested

Syntax checked with `dash -n`, and every run below used `dash`. All runs were against the practice
cluster (Prometheus v3.5.0, kind), with the git history from 2026-10-20 on (10,738 rows).

| Test | Result |
|---|---|
| Full run: dump, convert, blocks (Docker image already on the host), copy into the pod | 1 block of 572 series and 190,505 samples; loaded by Prometheus; 0 log errors |
| `gah2prom.py verify` on that import | matched 9,440, missing 0, unexpected 0 |
| Same data again with `--promtool-from-pod` (promtool taken out of the pod) | Worked; verify again 9,440 matched, 0 missing, 0 unexpected; blocks loaded went back to 1 because Prometheus merged them (no duplicates) |
| Missing `--pod`, unknown option | Clear error message |

Not tested: a live Grafana source, `oc`, a pod whose image has no `tar`, a local `promtool` in
`PATH`, HA with two pods, and the full 11-month history through this script (the full history was
imported earlier with the manual steps in `README.md`). The practice Prometheus was reset to empty
afterwards.
