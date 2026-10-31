# Design: moving alert state history from env1 Grafana into env2 Prometheus

## Options compared

| option | past history | going forward | verdict |
|---|---|---|---|
| (a) export annotations, convert to OpenMetrics with explicit timestamps, `promtool tsdb create-blocks-from openmetrics`, copy blocks into env2 data dir | yes, any age inside env2 retention | no (one-shot, can be re-run) | **chosen for past history** |
| (b) remote write of the converted samples into env2 (`--web.enable-remote-write-receiver`) | only if env2 enables `out_of_order_time_window` at least as long as the oldest history; this is a global TSDB setting on the production Prometheus | possible but needs a daemon | rejected for past history |
| (c) Grafana's own `prometheus` state-history backend | no, writes only new evaluations (research.md 1.1) | yes, Grafana 12.1+ only; env1 12.0.0 refuses the setting | **chosen for going forward**, after the upgrade to 12.1.x |

Why (a): it needs no config change on env2 Prometheus (no remote-write
receiver, no out-of-order window), it is offline and repeatable, its input is a
plain file that can be reviewed before import, and Prometheus loads the blocks
on its own within a minute. Its costs: shell access to env2's data volume and
`promtool` (shipped in every Prometheus image).

## Series model

One metric, `ALERTS_HISTORY`, with the same label names Grafana 12.1's
`GRAFANA_ALERTS` uses, so a dashboard can read both:

```
ALERTS_HISTORY{
  alertname="<rule title>",            # from the instance labels (Grafana always sets it)
  grafana_rule_uid="<uid>",            # alertId -> uid via the rule list
  alertstate="firing|pending",         # Prometheus ALERTS semantics
  grafana_alertstate="alerting|pending|nodata|error|recovering",
  <every instance label from the annotation text, e.g. grafana_folder, host, severity>,
  source="grafana-env1"                # keeps it apart from env2's own live series
}
```

- Different metric name (`ALERTS_HISTORY`, not `ALERTS` or `GRAFANA_ALERTS`)
  plus `source` label: no collision with env2's live Prometheus `ALERTS` or
  with `GRAFANA_ALERTS` written later by Grafana 12.1.
- Normal is not emitted, matching `GRAFANA_ALERTS`.
- Instance identity = (rule, full label set). `alertstate` and
  `grafana_alertstate` are part of the series, so a Pending -> Alerting change
  ends one series and starts another at the same millisecond.
- State reasons (`(Error)`, `(MissingSeries)`, `(Paused)`) are not labels.
  A reason-only change (`Alerting -> Alerting (Error)`) does not split the
  interval; `Alerting (Error)` counts as `alerting`.

## From events to samples

Annotations are events (one per change). Prometheus queries need samples. For
each instance the tool walks its events in time order and builds intervals
`[start, end)` per non-Normal state, then writes:

1. a sample `1` at exactly `start` (the annotation `time`, ms precision),
2. samples `1` on an epoch-aligned grid (`--step`, default 15s) strictly inside
   the interval. The grid is aligned to multiples of the step, not to the
   interval start, so two runs over the same data produce the same timestamps,
3. a sample `0` at exactly `end` (the next state's annotation time).

Why the trailing `0`: promtool cannot write stale markers (research.md 4).
Without an end sample, an instant query keeps returning the last `1` for the
lookback delta (5m by default) after the alert really resolved. With it, the
newest sample at `end` is `0`, so `ALERTS_HISTORY == 1` is exactly right at
every instant (lab proof: `lab-results/04-phase1-promql-proof.txt`, values at
`end - 1ms` = 1, at `end` = 0). The price: queries must filter `== 1`
(or `> 0`), and `count(ALERTS_HISTORY)` without the filter over-counts for up
to 5m after each end. `--end-marker none` drops the zero if a consumer cannot
filter.

Step choice: the step must be below env2's `--query.lookback-delta`
(default 5m) or instant queries see gaps inside long intervals. 15s keeps
`*_over_time` functions and `[1m]` range selectors usable. Cost: about 5,760
samples per instance per day of non-Normal state. Long-firing alerts dominate
the size; 1m is a reasonable choice for large histories.

### Edge rules

- **Interval open at export time** (last event is non-Normal): samples run up
  to the export `to` time (last grid point at or before it), no end marker. A
  later run with a later `to` adds the rest of the interval on the same grid
  (lab: `lab-results/08-phase2-verify.txt`).
- **Leading interval** (the first event of an instance in the dump has a
  non-Normal `prevState`, e.g. older rows were cleaned up by annotation
  retention): the state is known to be active before the first event, so the
  tool starts it at `max(--from, oldest annotation in the dump)`. It never goes
  further back. `--no-leading` disables this.
- **Gaps**: Normal periods have no samples at all; the zero at the end of the
  previous interval marks the boundary.
- **Same-millisecond conflicts** (an interval of a series starting at the exact
  millisecond another interval of the same series ends): the start (`1`) wins.
- **Labels**: names are sanitized like Grafana's own backend
  (`strutil.SanitizeFullLabelName`: invalid characters to `_`, `_` prefix if
  the name starts with a digit). Instance labels named `alertstate`,
  `grafana_alertstate`, `grafana_rule_uid`, `source` are dropped (counted in
  the convert stats) so they cannot override the model labels.
- **Rules deleted in env1**: `alertName` is empty and no UID mapping exists;
  the title is taken from the text before the first ` {` and
  `grafana_rule_uid="unknown-rule-id-<id>"`.

## Idempotency and re-runs

- `export` deduplicates by annotation `id` and writes a sorted, stable JSON.
- `convert` is a pure function of the dump: same dump, byte-identical
  OpenMetrics.
- Re-importing creates overlapping blocks with identical samples. Prometheus
  merges them at query time and in vertical compaction. Lab: importing the same
  data twice did not change any sample count or any reconstructed transition
  (`lab-results/09-phase3-reimport.txt`).
- Incremental runs: export a window that overlaps the previous one (start it at
  or before the oldest interval that was still open last time). Overlapping
  samples are identical, new ones extend the history.

## Blocks and retention

- promtool cuts 2h blocks aligned to 2h boundaries by default. A month of
  history becomes about 360 small blocks; Prometheus compacts them together
  over time. `--max-block-duration=24h` (or larger) reduces the count.
- env2 time retention deletes a whole block once
  `newest block MaxTime - block MaxTime >= retention`. History older than
  env2's retention is deleted at the next reload or compaction, so it is
  pointless to import it; trim the export with `--from` (lab:
  `lab-results/10-retention.txt`).
- Size-based retention (`--storage.tsdb.retention.size`) deletes the oldest
  blocks first, which are exactly the backfilled ones.

## Going forward

After env1 (or its successor on env2) runs Grafana 12.1.x:

```ini
[unified_alerting.state_history]
enabled = true
backend = multiple
primary = annotations          # keeps the Grafana UI history working
secondaries = prometheus
prometheus_target_datasource_uid = <env2 Prometheus datasource uid>
# prometheus_metric_name = GRAFANA_ALERTS (default)
```

and on the target datasource `jsonData.prometheusType: Prometheus`, and on env2
Prometheus `--web.enable-remote-write-receiver`. A single query then covers
both periods:

```promql
{__name__=~"ALERTS_HISTORY|GRAFANA_ALERTS", alertname="X"} == 1
```

Until the upgrade, ongoing history can be captured by re-running export,
convert and backfill on a schedule (for example daily, with a window that
overlaps the previous run by at least the longest open interval).
