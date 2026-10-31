#!/usr/bin/env python3
"""Independent spot check: rebuild one alert instance's state timeline straight from the
raw grafana-git-sync day files (no gah2prom code) and compare it with instant queries
against Prometheus at every transition: at t-1ms the old state must be active, at t the
new one (Normal = no `== 1` result).

Usage:
  spot_check.py <alert-history dir> --prometheus http://127.0.0.1:29190 \
      --alert-id 61 --match 'instance=10.0.0.1:9100' [--source grafana-git-history] [--max 40]

--match is a substring that must appear in the annotation text, to pick one instance.
Prints PASS/FAIL per check and a summary. Exit code 1 on any failure.
Python 3 standard library only.
"""
import argparse
import glob
import json
import os
import sys
import urllib.parse
import urllib.request


MODEL = {"__name__", "alertstate", "grafana_alertstate", "grafana_rule_uid"}


def q(prom, expr, t_ms, want, source_label):
    """States of the series whose labels are exactly `want` (matchers also match supersets)."""
    url = prom.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": "%.3f" % (t_ms / 1000)})
    with urllib.request.urlopen(url, timeout=60) as r:
        res = json.load(r)["data"]["result"]
    exact = [x for x in res if {k: v for k, v in x["metric"].items() if k not in MODEL | {source_label}} == want]
    return sorted(x["metric"].get("grafana_alertstate", "?") for x in exact)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("history_dir")
    p.add_argument("--prometheus", required=True)
    p.add_argument("--alert-id", type=int, required=True)
    p.add_argument("--match", required=True, help="substring of the annotation text that selects one instance")
    p.add_argument("--source", default="grafana-git-history")
    p.add_argument("--max", type=int, default=40, help="check at most this many transitions (spread over the history)")
    a = p.parse_args()

    rows = {}
    for f in sorted(glob.glob(os.path.join(a.history_dir, "*", "*", "*.jsonl"))):
        for line in open(f, encoding="utf-8"):
            if not line.strip():
                continue
            r = json.loads(line)
            if r["alertId"] == a.alert_id and a.match in r["text"]:
                rows[r["id"]] = r
    evs = sorted(rows.values(), key=lambda r: (r["time"], r["id"]))
    if not evs:
        sys.exit("no rows match")
    texts = {}
    for r in evs:
        texts.setdefault(r["text"].split("} - ")[0], []).append(r)
    labels_txt = max(texts, key=lambda k: len(texts[k]))
    if len(texts) > 1:
        print(f"--match selects {len(texts)} instances; checking the one with most rows")
    evs = texts[labels_txt]
    body = labels_txt[labels_txt.index(" {") + 2:]
    lbl = dict(kv.split("=", 1) for kv in body.split(", "))
    alertname = lbl["alertname"]
    sel = ", ".join('%s="%s"' % (k, v.replace("\\", "\\\\").replace('"', '\\"')) for k, v in sorted(lbl.items()))
    expr = "ALERTS_HISTORY{%s, source=\"%s\"} == 1" % (sel, a.source)

    base = lambda s: s.split(" ", 1)[0].lower()
    # collapse to base-state changes (reason-only changes do not split an interval)
    trans, cur = [], None
    for r in evs:
        st = base(r["newState"])
        if st != cur:
            trans.append((r["time"], cur, st))
            cur = st
    if len(trans) > a.max:
        step = len(trans) / a.max
        pick = sorted({int(i * step) for i in range(a.max)} | {len(trans) - 1})
        trans = [trans[i] for i in pick]
    print(f"instance: alert_id={a.alert_id} rows={len(evs)} base-state changes checked={len(trans)}")
    fails = 0
    for t, old, new in trans:
        exp_before = [] if old in (None, "normal") else [old]
        exp_at = [] if new == "normal" else [new]
        got_before = q(a.prometheus, expr, t - 1, lbl, "source")
        got_at = q(a.prometheus, expr, t, lbl, "source")
        ok = (old is None or got_before == exp_before) and got_at == exp_at
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} t={t} {old}->{new}  before={got_before} at={got_at}")
    print(f"summary: {len(trans) - fails}/{len(trans)} transitions match")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
