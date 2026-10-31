# Research: where Grafana 12.0 keeps alert state history, and how to read it

All source references are to the Grafana git tags `v12.0.0` and `v12.1.1`
(github.com/grafana/grafana) and Prometheus `v3.5.0`, read on 2026-10-31.
Lab confirmations are in `lab-results/`.

## 1. Storage backends

Config section `[unified_alerting.state_history]` (`conf/defaults.ini`):

| key | 12.0.0 | 12.1.1 |
|---|---|---|
| `enabled` | `true` | `true` |
| `backend` | empty = `annotations`; also `loki`, `multiple` | adds `prometheus` |
| `primary` / `secondaries` | for `multiple` | same; `secondaries` may contain `prometheus` |
| `prometheus_target_datasource_uid` | does not exist | required for `prometheus` |
| `prometheus_metric_name` | does not exist | default `GRAFANA_ALERTS` |
| `prometheus_write_timeout` | does not exist | default `10s` |

Evidence:

- `pkg/services/ngalert/state/historian/backend.go`: v12.0.0 defines
  `annotations`, `loki`, `multiple`, `noop` only. v12.1.0 and v12.1.1 add
  `BackendTypePrometheus = "prometheus"` (checked tags v12.0.2, v12.0.4: absent;
  v12.1.0: present).
- v12.1.1 `pkg/setting/setting_unified_alerting.go:70-71,468-470`: the three
  `prometheus_*` keys and their defaults.
- v12.1.1 `pkg/services/ngalert/ngalert.go:698-714`: `configureHistorianBackend`
  builds the Prometheus backend with no feature-toggle check. It is enabled by
  config alone.
- Lab: Grafana 12.0.0 started with `backend = prometheus` exits with
  `Error: ✗ unrecognized state history backend: prometheus`
  (`lab-results/00-grafana-12.0.0-prometheus-backend.txt`).

### 1.1 The 12.1 `prometheus` backend writes going forward only

v12.1.1 `pkg/services/ngalert/state/historian/prometheus.go`:

- `Query()` returns `prometheus historian backend does not support querying`.
- `Record()` is called from `state.Manager.ProcessEvalResults` with
  `allChanges` (every evaluated instance, every evaluation,
  `pkg/services/ngalert/state/manager.go:370-373`) and writes one sample per
  non-Normal instance at `LastEvaluationTime`, value `1`, plus a Prometheus
  stale marker (StaleNaN) for the previous state when the state changes.
- Labels: instance labels (private `__x__` labels removed),
  `alertname` = rule title, `grafana_rule_uid`, `alertstate`
  (`firing`/`pending`), `grafana_alertstate`
  (`alerting`/`pending`/`nodata`/`error`/`recovering`). Normal is not emitted.
- There is no code path that reads old annotations and replays them. Past
  history is not migrated.
- Write path is chosen by `pkg/services/ngalert/writer/datasourcewriter.go:109`
  `getRemoteWriteURL`: `/api/v1/write` only if the datasource has
  `jsonData.prometheusType: Prometheus`, otherwise Mimir paths (`/api/v1/push`).
  Target Prometheus needs `--web.enable-remote-write-receiver`.
- Lab: Grafana 12.1.1 with `backend=multiple, primary=annotations,
  secondaries=prometheus` delivered `GRAFANA_ALERTS` series to the lab
  Prometheus v3.5.0.

## 2. What the annotations backend stores (the source on 12.0)

`pkg/services/ngalert/state/historian/annotation.go:200-257` (v12.0.0),
one row in table `annotation` per recorded transition:

| column / API field | content |
|---|---|
| `alert_id` / `alertId` | numeric `alert_rule.id` (not the UID) |
| `epoch` / `time` | `LastEvaluationTime` in ms = transition time |
| `epoch_end` / `timeEnd` | same as `epoch` |
| `prev_state`, `new_state` | `State` or `State (Reason)`, e.g. `Alerting`, `Normal (MissingSeries)`, `Alerting (Error)` (`state.FormatStateAndReason`) |
| `text` | `<rule title> {<labels>} - <values>` |
| `data` | JSON: `{"values":{"B":1,"C":1}}`, or `{"noData":true}`, or `{"error":"..."}` |
| `dashboard_uid`, `panel_id` | only if the rule is linked to a panel |

- Instance labels are NOT stored as structured data. They exist only inside
  `text`, formatted by `data.Labels.String()` (grafana-plugin-sdk-go v0.275.0
  `data/labels.go:60`): keys sorted, `k=v` joined with `", "`, no quoting or
  escaping. Parsing is therefore exact unless a label value itself contains
  `", <something>="`.
- States: `Normal`, `Alerting`, `Pending`, `NoData`, `Error`, `Recovering`
  (`pkg/services/ngalert/eval/eval.go:309`).
- Not every evaluation is stored, only changes (`historian/core.go:20-59`):
  unchanged states are skipped; `Normal -> Normal (MissingSeries)`,
  `Normal (Paused|Updated) -> Normal`, `Normal <-> Normal (NoData)`, and
  transitions into `KeepLast` are skipped. Reason-only changes such as
  `Alerting -> Alerting (Error)` ARE stored.
- Retention: `[unified_alerting.state_history.annotations] max_age` and
  `max_annotations_to_keep` (default 0 = keep forever). Whatever env1 has
  already cleaned up cannot be recovered.

## 3. Export APIs

### 3.1 `GET /api/annotations?type=alert` (chosen)

`pkg/api/annotations.go:38-60`, `pkg/services/annotations/annotationsimpl/xorm_store.go:250-375` (v12.0.0):

- Filters: `type=alert` (`alert_id > 0`), `from`/`to` in ms (applied only if
  BOTH are > 0; condition `epoch <= to AND epoch_end >= from`, inclusive),
  `alertId`, `alertUID`, `dashboardUID`, `panelId`, `tags`.
- `limit` default 100 (`defaultAnnotationsLimit`), no upper cap in code.
- No offset or page parameter: `ItemQuery.Page` exists but the handler never
  sets it. Results are the newest `limit` rows by
  `ORDER BY a.org_id, a.epoch_end DESC, a.epoch DESC`.
  Paging must be done by shrinking the time window. The tool splits a window in
  two whenever a call returns `limit` rows (lab: 183 rows, limit 50, 49 calls,
  all 183 rows retrieved).
- Returns `alertName` via `LEFT JOIN alert_rule`, so it is empty for rules
  that were deleted. The rule UID is not returned; map `alertId` to UID with
  `GET /api/v1/provisioning/alert-rules` (each rule has `id`, `uid`, `title`)
  or `GET /api/ruler/grafana/api/v1/rules` (`grafana_alert.id`).
- Org scoped (`X-Grafana-Org-Id`), access-control filtered.

### 3.2 `GET /api/v1/rules/history` (not used)

`pkg/services/ngalert/api/tooling/definitions/ruler_state_history.go:5`. With the
annotations backend (`AnnotationBackend.Query`, `annotation.go:112-195`) it:
requires `ruleUID` (one rule per call), ignores label filters (logs a warning),
and returns a data frame of `time`, `text`, `prev`, `next`, `data`. It reads the
same rows as 3.1 and adds nothing but a per-rule call pattern. Its `time`
column is wrong with this backend: `time.Unix(item.Time, 0)` (`annotation.go:184`)
treats the ms epoch as seconds, so the frame time is 1000 times too large (lab:
`1793433410000000` from this API vs `1793433410000` from `/api/annotations` for
the same row, `lab-results/06-rules-history-api.txt`). It is the native API for
the Loki backend.

### 3.3 Direct SQL on `annotation` (fallback)

Same data as 3.1 (the API is a thin SELECT over this table). Use when the API is
too slow or blocked. Columns used: `id, alert_id, epoch, prev_state, new_state,
text, data`, joined to `alert_rule (id, uid, title)`. The runbook gives a query
that produces the tool's dump format.

## 4. Prometheus side (v3.5.0)

- `promtool tsdb create-blocks-from openmetrics <file> <outdir>`
  (`cmd/promtool/backfill.go`): default block duration 2h, blocks aligned to
  multiples of the block duration (`mint = blockDuration * (mint / blockDuration)`),
  `--max-block-duration` allows larger blocks.
- Block pickup: the TSDB loop reloads blocks from disk every minute
  (`tsdb/db.go:1090-1095`, `reloadBlocks()`). No restart needed. Lab: a copied
  block was loaded about 50 s after copy.
- Overlapping blocks are merged at query time and by vertical compaction.
  Lab on v3.5.0: importing the same data twice left every sample count
  unchanged and `prometheus_tsdb_vertical_compactions_total` went up
  (`lab-results/09-phase3-reimport.txt`). A block overlapping the head time
  range (history up to "now") also loaded without error
  (`lab-results/02-phase1-backfill.txt`).
- Time retention (`tsdb/db.go:1738` `BeyondTimeRetention`): a block is deleted
  when `newestBlock.MaxTime - block.MaxTime >= retention`. It is relative to the
  newest block, not to wall clock, and it deletes whole blocks.
- Stale markers: promtool's OpenMetrics parser reads `NaN` as an ordinary NaN,
  not the StaleNaN bit pattern, so a backfill cannot end a series the way a
  live scrape or Grafana's remote write does. The tool writes an explicit `0`
  sample at the exact end of each interval instead (see design.md).
