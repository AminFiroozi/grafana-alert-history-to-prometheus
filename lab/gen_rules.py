#!/usr/bin/env python3
"""Generate the lab's provisioned alert rules (JSON is accepted by Grafana file provisioning)."""
import json, sys

def rule(uid, title, scen, extra, thr, for_, nodata="NoData", err="Error", labels=None):
    return {
        "uid": uid, "title": title, "condition": "C",
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": 300, "to": 0}, "datasourceUid": "testdata",
             "model": dict({"refId": "A", "scenarioId": scen, "intervalMs": 1000, "maxDataPoints": 100}, **extra)},
            {"refId": "B", "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last"}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": "gt", "params": [thr]}}]}},
        ],
        "noDataState": nodata, "execErrState": err, "for": for_,
        "labels": labels or {}, "annotations": {"summary": title},
    }

doc = {"apiVersion": 1, "groups": [{
    "orgId": 1, "name": "lab-flap", "folder": "Lab", "interval": "10s",
    "rules": [
        # deterministic flapper: 60s on, 40s off
        rule("lab-pulse", "Lab Pulse", "predictable_pulse",
             {"pulseWave": {"timeStep": 10, "onCount": 6, "offCount": 4, "onValue": 1, "offValue": 0}},
             0.5, "0s", labels={"team": "sre", "severity": "warning"}),
        # 3 instances, random flapping, with a pending period
        rule("lab-walk", "Lab Walk Multi", "random_walk",
             {"seriesCount": 3, "startValue": 0, "min": -3, "max": 3, "spread": 1.5,
              "labels": "host=h$seriesIndex, env=lab"},
             0.0, "20s", labels={"team": "sre", "severity": "critical"}),
        # constant NoData -> interval still open at export time
        rule("lab-nodata", "Lab NoData", "no_data_points", {}, 0.5, "0s"),
        # constant query error -> Error state, open at export time
        rule("lab-error", "Lab Error", "server_error_500", {}, 0.5, "0s"),
    ]}]}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
