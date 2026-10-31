# Open questions and unverified points

Things not confirmed in source or in the lab. Resolve the production ones before
running the runbook.

## Production facts not known

1. **env2 Prometheus version.** Lab used v3.5.0. `promtool tsdb
   create-blocks-from openmetrics` is believed to exist since Prometheus 2.24,
   and overlapping blocks to be on by default since 2.39 (earlier versions need
   `--storage.tsdb.allow-overlapping-blocks`). Both from memory, not checked in
   source. Check `/api/v1/status/buildinfo` on env2.
2. **env2 retention** (`storage.tsdb.retention.time` / `.size`) decides how far
   back an import makes sense.
3. **How env2 Prometheus is deployed**: plain pod, Prometheus Operator, HA pair,
   Thanos sidecar or remote storage behind it. With Thanos sidecar, uploaded
   blocks may behave differently (not tested). With an HA pair, every replica
   needs the blocks.
4. **Write access to the env2 TSDB volume** (`kubectl cp` permission, pod
   security policies, read-only root filesystems).
5. **env1 Grafana DB engine** (SQLite / MySQL / PostgreSQL) and row count of
   `annotation WHERE alert_id > 0`. Only matters for the SQL fallback and for
   sizing.
6. **env1 annotation cleanup settings** (`[unified_alerting.state_history.annotations]
   max_age`, `max_annotations_to_keep`, and the general `[annotations]` cleanup).
   They decide how much history still exists.
7. **Number of orgs in env1.** The tool handles one org per run.
8. **Minimal permissions for the export token.** Lab used the admin user. An
   Admin-role service account should work; the least-privilege set
   (annotations read on alert annotations, alert rule read) was not tested.
9. **Is env1 going to be upgraded to 12.1.x**, or is env2's Grafana 12.1.1
   taking over the rules? That decides where the `prometheus` history backend
   is enabled going forward.

## Design points with some uncertainty

10. **Recovering state.** Mapped to `alertstate="firing"`,
    `grafana_alertstate="recovering"` like Grafana 12.1's backend, but no lab
    rule produced it (needs `keep_firing_for`).
11. **Label value edge case** (`", k="` inside a value) is detected, not
    handled. Unknown whether production labels ever contain this.
12. **Same-millisecond conflicts** (one series ending and starting again at the
    same ms) are resolved in favour of the start; the verify step would report
    the missing end. Not seen in the lab.
13. **Grafana 12.1 `GRAFANA_ALERTS` to vanilla Prometheus without
    `prometheusType: Prometheus`** returns 404 on `/api/v1/push`. Known from an
    earlier lab on this machine (12.2) and from `datasourcewriter.go`; not
    re-run here.
14. **Rollback via `delete_series`** not exercised.
