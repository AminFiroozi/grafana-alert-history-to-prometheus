# Grafana alert state history to Prometheus

Move Grafana unified-alerting state history (Grafana 12.0.x, stored as SQL
annotations) into a Prometheus TSDB, so that the past firing and pending
periods of every alert instance can be queried with PromQL and drawn in Grafana
next to live data.

Tested twice:

- a Docker lab with synthetic rules (445 annotations, `docs/test-results.md`
  part 1), and
- the real history kept by grafana-git-sync: 625,038 annotations, 154 rules,
  2025-12-10 to 2026-10-29, imported into a Prometheus v3.5.0 StatefulSet in a
  kind cluster and verified with 0 missing and 0 extra transitions
  (`docs/test-results.md` part 2).

## Contents

- [The problem](#the-problem)
- [Why this approach](#why-this-approach)
- [Data model: ALERTS_HISTORY and the `== 1` rule](#data-model-alerts_history-and-the--1-rule)
- [Architecture](#architecture)
- [Inputs supported](#inputs-supported)
- [Repository layout](#repository-layout)
- [Runbook](#runbook)
- [Practice environment](#practice-environment)

## The problem

Grafana 12.0 keeps alert state history in its SQL database, table
`annotation`, one row per state change (`docs/research.md` section 2). That
history is visible only in the Grafana UI, per rule, and it is lost if the
Grafana database is rebuilt or annotations are cleaned up. It cannot be queried
with PromQL, joined with other metrics, or kept in the long-term metrics store.

Grafana 12.1 adds a `prometheus` state-history backend that writes
`GRAFANA_ALERTS` series by remote write, but only for new evaluations. Nothing
in Grafana replays the old annotations (`docs/research.md` 1.1). The past has to
be moved by hand.

## Why this approach

Export the annotation rows, turn every state interval into Prometheus samples
with their original timestamps, build TSDB blocks offline with
`promtool tsdb create-blocks-from openmetrics`, and copy the blocks into the
target Prometheus data directory.

- No config change on the target Prometheus: no remote-write receiver and no
  out-of-order window (remote write of samples months old needs
  `out_of_order_time_window` as long as the history, a global TSDB setting).
- Offline and repeatable: the input is a file that can be reviewed, the
  conversion is a pure function (same dump in, byte-identical file out), and a
  re-import of the same data is harmless (overlapping identical samples are
  merged).
- Prometheus picks new block directories up by itself within a minute; no
  restart.
- Exact: interval starts and ends keep millisecond precision, and the `verify`
  step proves it by rebuilding every transition from raw samples.

Options compared in `docs/design.md`.

## Data model: ALERTS_HISTORY and the `== 1` rule

One metric, with the label names Grafana 12.1 uses for `GRAFANA_ALERTS`:

```
ALERTS_HISTORY{
  alertname="<rule title at the time of the change>",
  grafana_rule_uid="<rule uid>" | "unknown-rule-id-<numeric id>",   # deleted rules
  alertstate="firing" | "pending",
  grafana_alertstate="alerting" | "pending" | "recovering" | "nodata" | "error",
  <every instance label from the annotation text>,
  source="<name of the source, e.g. grafana-git-history>"
}
```

- Normal is not stored: no series means Normal.
- State reasons in parentheses are dropped: `Alerting (NoData)` is `alerting`,
  `Normal (MissingSeries)` and `Normal (Paused)` are Normal.
- `Recovering` (the `keep_firing_for` period) is `alertstate="firing"`,
  `grafana_alertstate="recovering"`, the same mapping as Grafana 12.1's own
  backend (`docs/design.md`, "State mapping", with source references).

Samples per interval `[start, end)`: a `1` at exactly `start`, `1` every
`--step` on an epoch-aligned grid, and a `0` at exactly `end`.

**Always filter with `== 1`** (or `> 0`). promtool cannot write Prometheus
stale markers, so the `0` at `end` is the exact end marker. With the filter, an
instant query at any moment returns exactly the instances that were in that
state. Without it, an ended interval is still returned (with value 0) for up to
the lookback delta (5m).

```promql
ALERTS_HISTORY{source="grafana-git-history"} == 1                       # active at an instant
count by (alertname) (ALERTS_HISTORY{alertstate="firing"} == 1)         # firing instances per rule
{__name__=~"ALERTS_HISTORY|GRAFANA_ALERTS", alertname="X"} == 1         # history plus live 12.1 data
```

## Architecture

```
  INPUTS (pick one)                       ADAPTER                     tool/gah2prom.py
 +-------------------------------+
 | Grafana 12.0 HTTP API         |--> gah2prom.py export ---+
 | /api/annotations?type=alert   |                          |
 +-------------------------------+                          |
 | Grafana SQL DB, table         |--> csv_to_dump.py -------+--> dump.json --> convert --> *.om
 | annotation (CSV export)       |                          |   (rows +       (intervals,  (OpenMetrics,
 +-------------------------------+                          |    rule map)     1m grid,     one file per
 | grafana-git-sync repo         |--> gitsync_to_dump.py ---+                  0 at end)    486h window)
 | alert-history/YYYY/MM/*.jsonl |                                                            |
 +-------------------------------+                                                            v
                                                   promtool tsdb create-blocks-from openmetrics
                                                   (same version as target, outside the pod)
                                                                                              |
                                                                                    TSDB blocks/<ULID>
                                                                                              |
                         kubectl cp -> /prometheus/<ULID>.tmp-for-creation, then mv to <ULID>
                                                                                              v
 +--------------------------------------------------------------------------------------------+
 | target Prometheus (StatefulSet prometheus, pod prometheus-0, PVC at /prometheus)            |
 |   reloads blocks from disk every minute, keeps them while inside time retention            |
 +--------------------------------------------------------------------------------------------+
        ^                                        |
        | gah2prom.py verify                     | PromQL: ALERTS_HISTORY{...} == 1
        | (dump vs raw samples, 0/0 = pass)      v
        |                                  Grafana 12.1 dashboard "Alert state history (backfilled)"
```

## Inputs supported

| input | command | when |
|---|---|---|
| Grafana HTTP API | `tool/gah2prom.py export --url ... --token ...` | normal case: Grafana is reachable |
| Grafana SQL database | SQL in the header of `tool/csv_to_dump.py`, then `csv_to_dump.py` | API blocked or too slow |
| grafana-git-sync history in git | `tool/gitsync_to_dump.py <repo checkout>` | history already backed up to git by grafana-git-sync (`alert-history/YYYY/MM/YYYY-MM-DD.jsonl`), no access to Grafana needed |

All three write the same dump format (`{"from","to","rules":{id:{uid,title}},"annotations":[...]}`),
so `convert` and `verify` are the same for every input.

## Repository layout

| path | content |
|---|---|
| `tool/gah2prom.py` | `export` (Grafana API), `convert` (dump to OpenMetrics), `verify` (dump vs Prometheus). Python 3 standard library only |
| `tool/gitsync_to_dump.py` | adapter: grafana-git-sync `alert-history/` day files to dump, dedupe by annotation id |
| `tool/csv_to_dump.py` | adapter: SQL `annotation` table CSV to dump |
| `tool/spot_check.py` | independent check of one instance: raw day files vs instant queries |
| `practice/` | kind cluster `ahpractice` with Prometheus v3.5.0 and Grafana 12.1.1, practice env1 Grafana 12.0.0; see `practice/PRACTICE.md` |
| `lab/` | the first Docker lab (env1 Grafana 12.0.0, env2 Prometheus + Grafana 12.1.1) |
| `docs/research.md` | where Grafana 12.0/12.1 keep history, APIs, state machine, Prometheus backfill behaviour, with source file:line |
| `docs/design.md` | options, series model, state mapping, events to samples, step and block size, deleted rules |
| `docs/limitations.md` | what this cannot do |
| `docs/open-questions.md` | unverified points |
| `docs/test-results.md` | lab results and the real-data run |
| `docs/lab-results/` | raw command output of the Docker lab |

Real alert data (dumps, OpenMetrics files, blocks) is never committed: it holds
internal rule names, URIs and service names. Put it under `work/`, which is
ignored.

# Runbook

Scope: source Grafana 12.0.x with the annotations state-history backend (the
default), or a grafana-git-sync backup of it; target Prometheus 3.x on
Kubernetes. Tested end to end against Grafana 12.0.0 and Prometheus v3.5.0
(`docs/test-results.md`). Points not checked against production are in
`docs/open-questions.md`; resolve them before phase 4.

Names used below: source Grafana = env1, target Prometheus = env2,
`$NS` = env2 namespace, `$POD` = env2 Prometheus pod (container `prometheus`,
TSDB at `/prometheus`).

## 0. Prerequisites

| what | how to check |
|---|---|
| Python 3.7+ on a host that can read the input and reach env2 Prometheus | `python3 --version` |
| env1 token able to read alert annotations and the rule list (API input only; an Admin service account works) | `curl -H "Authorization: Bearer $TOKEN" "$ENV1/api/annotations?type=alert&limit=1"` returns one row |
| env2 Prometheus version, retention, data path, lookback delta | `/api/v1/status/buildinfo`, `/api/v1/status/flags` (`storage.tsdb.retention.time`, `storage.tsdb.retention.size`, `storage.tsdb.path`, `query.lookback-delta`) |
| `promtool` of the same Prometheus version | ships in the Prometheus image |
| write access to env2's TSDB directory | `kubectl -n $NS exec $POD -c prometheus -- ls /prometheus` |
| disk: work space for the OpenMetrics files (large, see phase 2) and free space on env2 for the blocks (small) | `df -h .`, `kubectl exec ... -- df -h /prometheus` |

**Retention check.** Prometheus time retention is measured from the newest
block's max time, not from the wall clock (`tsdb/db.go` `BeyondTimeRetention`:
a block is deleted once `newest.MaxTime - block.MaxTime >= retention`). Since
env2 also has live data, the newest block is roughly "now". So:
`FROM >= now - retention + 1d`. Older data is deleted at the next reload
(`docs/lab-results/10-retention.txt`). Size retention removes the oldest blocks
first, which are exactly the backfilled ones; check it too.

## 1. Get a dump

Pick one input.

**a) Grafana API**

```bash
export ENV1=https://<env1-grafana> TOKEN=<service account token>
python3 tool/gah2prom.py export --url "$ENV1" --token "$TOKEN" \
  --from 2026-09-01T00:00:00Z --to now -o work/dump.json
# --org-id N for another org (one org per run); --insecure for self-signed TLS
```

Expect `rules: N` and `annotations: M rows in K API calls`. The API has no
offset paging, so the tool splits any window that returns `--limit` rows
(default 5000) until each window is under the limit. Cross-check once against
the DB if possible:

```sql
SELECT count(*) FROM annotation WHERE alert_id > 0 AND org_id = 1
  AND epoch BETWEEN <from_ms> AND <to_ms>;
```

**b) SQL fallback**: run the SQL in the header of `tool/csv_to_dump.py`, save
it as CSV, then
`python3 tool/csv_to_dump.py annotations.csv --from <from_ms> --to <to_ms> -o work/dump.json`.
In the lab this gave a byte-identical OpenMetrics file to the API path.

**c) grafana-git-sync history in git** (no Grafana access needed)

```bash
git -C <g-sync checkout> pull            # newest history first
python3 tool/gitsync_to_dump.py <g-sync checkout> -o work/dump.json
# optional: --from 2026-01-01 --to 2026-07-01T00:00:00Z (row time filter, also skips day files)
```

- Reads `<checkout>/alert-history/YYYY/MM/YYYY-MM-DD.jsonl` (one Grafana
  annotation row per line, filed by UTC day of `time`). The checkout is only
  read.
- Deduplicates by annotation `id`. grafana-git-sync never removes rows and keeps
  a second line when a known id comes back with different content; the adapter
  keeps the first copy and prints `dup_identical` / `dup_conflicting`.
- Rule map (`alertId` to uid/title) comes from
  `<checkout>/alerting/rules/<folder-uid>/<group>/<rule-uid>.json`, which carry
  the numeric `id`. `alerting/rules-export/` has no id and is not used. Rules
  that are not in the map (deleted) still work: labels and `alertname` come from
  the annotation text.
- Export end (`to`) is `history.cursorMs` in `<checkout>/.grafana-sync/state.json`
  (the moment the sync tool had read up to), or `--to`.
- Real run: 324 files, 625,038 rows, 0 duplicates, 10 s, 900 MB peak RSS.

## 2. Convert to OpenMetrics

First estimate the size. Samples are about
`sum over intervals of (duration / step) + 2 per interval`. The real history
had 1.7 million instance-hours of non-Normal state: about 410 million samples
at `--step 15s`, 103 million at `--step 1m`. One OpenMetrics line is about
320 bytes with real label sets, so even 1m gives about 29 GB of text.

```bash
python3 tool/gah2prom.py convert -i work/dump.json -o work/om --split 486h \
  --step 1m --source grafana-git-history --deleted-rule-end last-event
```

- `--step 1m`: must stay below env2's `--query.lookback-delta` (default 5m), or
  instant queries see gaps inside long intervals. 1m keeps every instant query
  exact (start and end are exact to the ms anyway) and `[1m]` or longer range
  selectors usable, at a quarter of the 15s size. Use 15s only for small
  histories.
- `--split 486h`: writes one file per epoch-aligned 486h window into the
  directory `work/om`. promtool re-reads its whole input once per block window
  (`cmd/promtool/backfill.go` `createBlocks`), so one 29 GB file with many
  windows would be parsed many times. With one file per window, each file is
  parsed for exactly one block. 486h is one of promtool's allowed block lengths
  (2h times powers of 3) and below the 31d cap Prometheus uses for its own
  compaction. For histories of a few days, skip `--split` and pass a file name.
- `--deleted-rule-end last-event`: Grafana writes no history row when a rule is
  deleted (`docs/research.md` 5.3), so the last state of a deleted rule looks
  open until the export end. With this option, a still-open interval of a rule
  that is not in the rule map stops at that rule's newest annotation. Use it
  whenever the dump has a rule map; it changes nothing for existing rules.
- Read the stats line: `label_parse_ambiguous`, `unknown_state`,
  `reserved_label_overridden` should be 0 or explained (WARN lines name the
  annotation ids). `rule_not_found` counts rows of deleted rules.
- Real run: 115 s, 1.2 GB peak RSS, 16 files, 29.3 GB, 90,492,858 samples.

## 3. Build TSDB blocks with promtool

Same Prometheus version as env2, outside the live data directory:

```bash
mkdir -p work/blocks
ls work/om/*.om | xargs -P 4 -I{} docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/work":/w \
  --entrypoint promtool prom/prometheus:<env2 version> \
  tsdb create-blocks-from openmetrics --max-block-duration=486h /w/{#work/} /w/blocks
```

(`{#work/}` is not shell syntax; write the path relative to `work`, for example
`cd work && ls om/*.om | xargs ... /w/{} /w/blocks`.)

- `--max-block-duration` must equal the `--split` value, so each file becomes
  exactly one block.
- Without `--split`: `promtool tsdb create-blocks-from openmetrics work/history.om work/blocks`
  (2h blocks by default).
- It prints one line per block (ULID, min and max time, samples, chunks,
  series, size). The sum of samples must equal `samples` from convert.
- Real run: 16 blocks, 139 s with 4 in parallel, 57.6 MB in total
  (constant values compress to well under 1 byte per sample).

## 4. Copy the blocks into env2 Prometheus

Copy each block under a temporary name, then rename it inside the pod. The TSDB
only loads directories whose name is a valid ULID (`tsdb/db.go` `isBlockDir`),
so a half-copied `<ULID>.tmp-for-creation` is never read, and Prometheus deletes
such leftovers at its next start (`isTmpDir`, `removeBestEffortTmpDirs`). The
`mv` inside one filesystem is atomic.

```bash
for b in work/blocks/01*; do
  u=$(basename "$b")
  kubectl -n $NS cp "$b" $POD:/prometheus/$u.tmp-for-creation -c prometheus
done
kubectl -n $NS exec $POD -c prometheus -- sh -c \
  'cd /prometheus && for d in *.tmp-for-creation; do mv "$d" "${d%.tmp-for-creation}"; done'
```

The Prometheus image has `tar`, so `kubectl cp` works, and the files are owned
by the container user. Plain Docker instead: `docker cp`, then
`docker exec -u 0 <container> chown -R nobody:nobody /prometheus/<ULID>`.

No restart. The TSDB reloads blocks from disk every minute. Within about a
minute check:

```promql
prometheus_tsdb_blocks_loaded               # went up by the number of blocks
prometheus_tsdb_reloads_failures_total      # unchanged
prometheus_tsdb_time_retentions_total       # unchanged (else retention deleted something)
prometheus_tsdb_lowest_timestamp_seconds    # now the start of the history
prometheus_tsdb_vertical_compactions_total  # goes up later if blocks overlapped
```

and `kubectl -n $NS logs $POD -c prometheus | grep -iE 'level=(error|warn)'`.
If Prometheus runs as an HA pair, repeat phase 4 on every replica.

Real run: copy 2 s, all 16 blocks loaded within 40 s, 0 reload failures, 0
retention deletions, no warnings in the log.

## 5. Verify

```bash
python3 tool/gah2prom.py verify -i work/dump.json --prometheus http://<env2-prometheus> \
  --source grafana-git-history --deleted-rule-end last-event
```

Use the same `--source`, `--deleted-rule-end` and `--no-leading` choices as in
convert. It rebuilds every interval start and end from the raw samples and
diffs them against the dump. Pass = `missing_in_prometheus: 0`,
`unexpected_in_prometheus: 0`, exit code 0. If env2 retention cut part of the
range, the oldest events show as MISSING (expected).

Independent spot check of single instances (reads the raw day files, not the
dump, and queries `== 1` just before and at every transition):

```bash
python3 tool/spot_check.py <g-sync checkout>/alert-history --prometheus http://<env2-prometheus> \
  --alert-id <numeric rule id> --match '<substring of the annotation text>'
```

Spot checks in Grafana Explore:

```promql
ALERTS_HISTORY{source="grafana-git-history"} == 1
count by (alertname) (count_over_time((ALERTS_HISTORY{source="grafana-git-history"} == 1)[1d:1m]))
changes(ALERTS_HISTORY{alertname="<rule>", source="grafana-git-history"}[7d])
```

## 6. Going forward

Until env1 runs Grafana 12.1.x, repeat phases 1 to 5 on a schedule. Each run
must start at or before the start of the oldest interval that was still open
last time (simplest: always from the same fixed start). Overlapping data is
identical and merged (`docs/lab-results/09-phase3-reimport.txt`).

After the upgrade to 12.1.x, enable live writes and stop the batch job:

```ini
[unified_alerting.state_history]
backend = multiple
primary = annotations
secondaries = prometheus
prometheus_target_datasource_uid = <uid of the env2 Prometheus datasource>
```

- The env2 datasource in that Grafana needs `jsonData.prometheusType: Prometheus`,
  or Grafana posts to `/api/v1/push` and gets 404 from vanilla Prometheus.
- env2 Prometheus needs `--web.enable-remote-write-receiver`.
- Do a final batch export up to the cut-over so there is no gap.
- Old and new together: `{__name__=~"ALERTS_HISTORY|GRAFANA_ALERTS", alertname="X"} == 1`.

## Rollback

Blocks that overlap other data get merged by compaction, so deleting block
directories is not a safe rollback. Use the admin API (needs
`--web.enable-admin-api`):

```bash
curl -X POST -g "$PROM/api/v1/admin/tsdb/delete_series?match[]=ALERTS_HISTORY{source=\"grafana-git-history\"}"
curl -X POST "$PROM/api/v1/admin/tsdb/clean_tombstones"
```

# Practice environment

`practice/` builds a small copy of the target: kind cluster `ahpractice` with
namespace `monitoring`, Prometheus v3.5.0 as StatefulSet `prometheus` (pod
`prometheus-0`, container `prometheus`, 20Gi PVC at `/prometheus`,
`--storage.tsdb.retention.time=400d`, `--web.enable-admin-api`, self-scrape),
Grafana 12.1.1 with a provisioned Prometheus datasource
(`prometheusType: Prometheus`) and the dashboard "Alert state history
(backfilled)". Both are exposed on host loopback through kind
`extraPortMappings` and NodePorts. A practice env1 (Grafana 12.0.0 in Docker,
synthetic rules) can be started too.

```bash
SKIP_ENV1=1 practice/up.sh     # env2 only; without SKIP_ENV1 also env1 + seeded history
export KUBECONFIG=$PWD/practice/kubeconfig
practice/reset-env2.sh         # wipe env2 Prometheus data, then redo runbook phases 4 and 5
practice/down.sh               # delete the cluster and env1
```

The separate kubeconfig file keeps every command away from other kind
clusters on the same host. URLs, login and a step-by-step redo of the real
import are in `practice/PRACTICE.md`.
