# Limitations

## Of the source data (env1, annotations backend)

- **Only what env1 still has.** Rows already removed by
  `[unified_alerting.state_history.annotations] max_age` /
  `max_annotations_to_keep` are gone.
- **Changes only, not evaluations.** Each row is a change. Several changes are
  never recorded at all (`historian/core.go`: Normal to Normal (MissingSeries),
  Normal (Paused/Updated) to Normal, Normal to Normal (NoData), entering
  KeepLast). The rebuilt history is exactly as good as the annotation log.
- **Labels come from free text.** The annotation `text` holds labels as
  `k=v, k=v` with no escaping. A label value containing `", <word>="` cannot be
  split with certainty. The tool checks that parsed keys are sorted and unique
  (Grafana writes them sorted) and logs `label_parse_ambiguous` with the row id
  when that check fails, but it cannot repair such rows.
- **Evaluation values are not exported.** `data.values` (for example
  `B=1.74`) stays in the dump JSON only; no metric is generated for it.
- **State reasons are dropped.** `Alerting (Error)` becomes `alerting`;
  `Normal (MissingSeries)` becomes the end of the interval.
- **Deleted rules** have no UID mapping: `grafana_rule_uid="unknown-rule-id-<id>"`,
  title taken from the text.
- **Windowed exports miss quiet instances.** An instance whose last change was
  before `--from` has no row in the window, so its ongoing state is not
  exported (lab: a partial export saw 4 of 6 instances,
  `lab-results/13-leading-interval.txt`). Export from the start of the needed
  history every time, or at least from before the oldest still-open interval.
- **Leading intervals are a lower bound.** If an instance's first row in the
  dump has a non-Normal `prevState`, the tool starts that interval at
  `max(--from, oldest row in the dump)`, not at the real (unknown) start.

## Of the Prometheus representation

- **End marker instead of staleness.** promtool cannot write stale markers, so
  each interval ends with a `0` sample. Queries must use `== 1` (or `> 0`).
  Without the filter, an ended interval still shows for up to the lookback
  delta (5m default) with value 0.
- **Sampled, not continuous.** Inside an interval the samples sit on a 15s grid
  (configurable). Start and end are exact to the millisecond; `*_over_time`
  results depend on the step.
- **Open intervals stop at the export time.** Until the next run, an alert that
  was still firing at export looks like it stopped at that moment (no end
  marker, the series just goes stale after the lookback delta).
- **Not the same metric as live alerts.** `ALERTS_HISTORY` is separate from
  Prometheus `ALERTS` and from Grafana 12.1 `GRAFANA_ALERTS`; dashboards need a
  `__name__=~` union to show both periods.
- **Retention applies.** Anything older than env2's time retention (measured
  from the newest block, not wall clock) is deleted at the next reload; size
  retention removes the oldest blocks first, which are the backfilled ones.
- **Blocks.** 2h blocks by default, so a long history means many small blocks
  until compaction merges them.
- **Rollback** is by `delete_series` on the admin API, not by deleting block
  directories, once compaction has merged blocks.

## Of the tool

- One Grafana org per run.
- Python 3.7+ standard library (uses `datetime.fromisoformat`; tested on 3.13).
- The dump holds full annotation text in memory; very large histories (millions
  of rows) were not tested.
- `export` walks `--from 1` (1970) by halving windows when it hits `--limit`; with
  a tight limit that costs many calls (lab: 49 calls for 183 rows at limit 50, 1
  call at the default 5000). Set `--from` near the real start of history for
  big exports.

## Added after the real data run

- Deleted rules: end time of open intervals is an estimate (last event).
- Empty label values are dropped (Prometheus does the same).
- 1m step: state changes shorter than the step inside one minute are
  represented by their first and last sample times only.
- Convert needs about 1.2 GB RAM and 30 GB temporary disk for 625k rows.
