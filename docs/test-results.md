# Lab test results (2026-10-31)

Raw commands and outputs: `lab-results/NN-*.txt`. Lab definition: `../lab/`.

## Lab setup

| component | image | role |
|---|---|---|
| env1-grafana | `grafana/grafana:12.0.0` | source, `backend = annotations`, SQLite |
| env2-prometheus | `prom/prometheus:v3.5.0` | target, retention 15d, `--web.enable-remote-write-receiver` |
| env2-grafana | `grafana/grafana:12.1.1` | going-forward demo, `backend = multiple`, `secondaries = prometheus` |

Four provisioned rules on a TestData datasource, group interval 10s
(`../lab/gen_rules.py`):

| rule | behaviour | states seen |
|---|---|---|
| Lab Pulse | predictable pulse, 60s on / 40s off, `for: 0s` | Normal, Alerting |
| Lab Walk Multi | random walk, 3 instances (`host=h0..h2`), `for: 20s` | Normal, Pending, Alerting |
| Lab NoData | always empty | NoData, open at export |
| Lab Error | always a query error | Error, open at export |

History accumulated from 07:39:00Z to 07:55:10Z (about 16 minutes): 183
annotations (Alerting 25, Pending 73, Normal 83, NoData 1, Error 1).

## Results

| # | test | result |
|---|---|---|
| 0 | Grafana 12.0.0 with `backend = prometheus` | refuses to start: `unrecognized state history backend: prometheus` |
| 0b | Grafana 12.1.1 `multiple` + `secondaries = prometheus` | `GRAFANA_ALERTS` series arrive in env2 Prometheus |
| 1 | export with `--limit 50` (forces window splitting) | 183 of 183 rows in 49 API calls |
| 2 | convert dump-1 | 6 instances, 100 intervals (2 open), 9 series, 427 samples |
| 3 | promtool + copy, no restart | 1 block, loaded by the 1-minute reload about 50 s after copy; block overlapped the head time range, no error |
| 4 | **verify dump-1** | **198 source events (100 starts + 98 ends), 198 reconstructed, 198 matched, 0 missing, 0 unexpected**; 427 samples read = 427 written |
| 5 | point checks, first Lab Pulse interval `[1793432340.000, 1793432370.000)` | `== 1` empty at `start - 1ms`, `1` at `start`, `1` at `end - 1ms`, empty at `end` (raw value 0) |
| 6 | open intervals at export | Lab Error and Lab NoData are `1` at the export instant, no end marker |
| 7 | old data: real rows copied to -6h and -30h in env1's DB, full re-export | 445 rows, 1 API call; 238 intervals (3 open), 9 series, 29,519 samples, 16 blocks from 2026-10-30T01:39Z |
| 8 | **verify dump-2** (on top of the phase-1 block, overlapping) | **473 source events (238 starts + 235 ends), 473 matched, 0 missing, 0 unexpected**; 29,519 samples read = 29,519 written |
| 9 | open interval extended by a later run | the 2 intervals open in dump-1 continue seamlessly in dump-2 (included in the 473 matches, no spurious start or end) |
| 10 | **re-import identical data** (same OpenMetrics, sha256 equal, new block ULIDs) | after reload and vertical compaction (`vertical_compactions_total` 7): every block's sample count unchanged, `sum(count_over_time(...[2d]))` = 29,519, verify 473/473, 0/0 |
| 11 | retention: fresh Prometheus with `retention.time=24h`, same 16 blocks | exactly the 3 blocks with `maxTime <= newestMaxTime - 24h` deleted at the first reload (`Deleting obsolete block`), oldest kept block starts 1793340000000; verify then reports 351 matched, 122 missing, 4 unexpected (the 4 = first kept sample of intervals cut by the deleted blocks) |
| 12 | backfilled `ALERTS_HISTORY` (env1 12.0.0) vs live `GRAFANA_ALERTS` (env2 12.1.1) for the same deterministic rule | identical firing windows over 07:50:00 to 07:57:50 at 10s resolution with one union query |
| 13 | SQL fallback (`annotation` table to CSV to dump) vs API path, same range | byte-identical OpenMetrics (sha256 `3636b267...`) |
| 14 | `/api/v1/rules/history` with the annotations backend | `time` column 1000 times too large (ms read as seconds) |
| 15 | partial export starting mid-history (leading interval logic) | found a bug: zero-length leading interval produced a wrong `1` sample; fixed in `intervals_for()`; full-history output unchanged after the fix (same sha256, verify 473/473) |

## What was not tested

- Remote-write path for past history (option b in design.md); rejected on design grounds.
- `--end-marker none`, `--step` other than 15s, `--max-block-duration`.
- A rule deleted in env1 before export (`unknown-rule-id-*` path), labels with
  `", k="` inside a value, multiple orgs, a token instead of basic auth.
- Grafana on MySQL or PostgreSQL (lab used SQLite; the SQL in
  `../tool/csv_to_dump.py` is plain ANSI but was only run on SQLite).
- Kubernetes `kubectl cp` into a Prometheus pod, Prometheus Operator, HA pairs.
- Rollback with `delete_series`.
- Prometheus 2.x as env2.
- Volume: the lab had 445 annotations; production row counts are unknown.

## Part 2: real data run (2026-10-31)

Input: git-synced alert history, 324 day files, 625,038 rows, 154 alertIds,
2025-12-10 to 2026-10-29. Target: new Prometheus v3.5.0 in kind cluster
`ahpractice`, retention 400d.

| Phase | Result | Time |
|---|---|---|
| reset env2 (delete StatefulSet and PVC, reapply) | clean | 36 s |
| git adapter (`gitsync_to_dump.py`) | 625,038 rows, 0 duplicate ids (identical 0, conflicting 0), 0 without id, dump 336,587,431 bytes, peak RSS 900 MB | 10.3 s |
| convert (`--step 1m --split --deleted-rule-end last-event`) | 11,836 instances, 336,096 intervals (164 open), 9,788 series, 90,492,858 samples, 16 files, 29,263,198,909 bytes, peak RSS 1.2 GB | 441 s |
| promtool create-blocks-from (`-P 4`, 486h) | 16 blocks, 57,564,965 bytes | 139 s (first run) |
| kubectl cp to `.tmp-for-creation` name, then mv | ok | 1 to 2 s |
| Prometheus reload | `blocks_loaded` 16 after 71 s, 0 reload failures, 0 retention deletions, 0 warn/error log lines, lowest timestamp 1765351300 (2025-12-10T07:21:40Z) | 71 s |
| verify | 672,028 source events, 672,028 matched, **0 missing, 0 unexpected**, 90,492,858 samples read | 80 s |
| spot check, 3 alerts | 61/61, 30/30, 81/81 transitions match (instant query `== 1` at t-1ms and t) | seconds |

Run 1 (before the empty label fix) gave 14 missing and 14 extra; cause in
research.md 5.1. The dashboard `alert-history-backfill` and the datasource
`env2prom` were provisioned and answer queries. Raw logs are kept outside
the repo (`work/`, ignored).

Not done: a second identical import on the real data (idempotency was shown
in lab test 10 only).
