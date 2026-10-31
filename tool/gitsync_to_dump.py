#!/usr/bin/env python3
"""Build a gah2prom dump from the alert history that grafana-git-sync stores in git.

grafana-git-sync (src/grafana_git_sync/history.py) writes every row of
`GET /api/annotations?type=alert` as one JSON line into UTC day files:

  <repo>/alert-history/YYYY/MM/YYYY-MM-DD.jsonl

A row is filed by its `time`, so it lives in exactly one day file. Rows are never
removed; a row whose id is already stored but whose content differs (apart from
`alertName`) is kept as an extra line. This adapter therefore deduplicates by
annotation `id` (first stored copy wins, like the sync tool) and reports how many
duplicates it dropped.

Rule map (alertId -> uid/title): read from the per-rule files the sync tool
writes under `<repo>/alerting/rules/<folder-uid>/<group>/<rule-uid>.json`, which
carry the numeric `id`. `alerting/rules-export/` has no numeric id and is not
used. Rules missing from the map (deleted rules) are fine: convert takes
alertname and labels from the annotation `text`.

Export end (`to`): `--to`, else `history.cursorMs` from `<repo>/.grafana-sync/state.json`
(the instant the sync tool had read up to), else the newest row time.

Usage:
  gitsync_to_dump.py /path/to/g-sync-test -o dump.json [--from 2026-01-01] [--to 2026-02-01T00:00:00Z]

Python 3 standard library only. The repo is only read, never written.
"""
import argparse
import datetime
import glob
import json
import os
import re
import resource
import sys
import time

KEEP = ("id", "alertId", "alertName", "time", "timeEnd", "prevState", "newState", "text", "data",
        "dashboardUID", "panelId")
DAY_MS = 86_400_000


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def parse_time(s):
    """epoch ms, epoch s, YYYY-MM-DD (00:00 UTC) or RFC3339 (UTC if no zone)."""
    s = s.strip()
    if re.fullmatch(r"\d+", s):
        v = int(s)
        return v if v > 10**11 else v * 1000
    dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp() * 1000)


def iso(ms):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + ".%03dZ" % (ms % 1000)


def day_start(path):
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})\.jsonl$", path)
    if not m:
        return None
    d = datetime.datetime(int(m[1]), int(m[2]), int(m[3]), tzinfo=datetime.timezone.utc)
    return int(d.timestamp() * 1000)


def load_rules(rules_dir):
    rules, files, no_id = {}, 0, 0
    for f in sorted(glob.glob(os.path.join(rules_dir, "**", "*.json"), recursive=True)):
        files += 1
        try:
            d = json.load(open(f, encoding="utf-8"))
        except ValueError as e:
            log(f"WARN {f}: not JSON ({e}), skipped")
            continue
        if not isinstance(d, dict) or not isinstance(d.get("id"), int) or not d.get("uid"):
            no_id += 1
            continue
        rules[str(d["id"])] = {"uid": d["uid"], "title": d.get("title", "")}
    log(f"rules: {len(rules)} with numeric id from {files} files in {rules_dir}" +
        (f" ({no_id} without id ignored)" if no_id else ""))
    return rules


def identity(row):
    return json.dumps({k: v for k, v in row.items() if k != "alertName"}, sort_keys=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("repo", help="grafana-git-sync checkout (contains alert-history/)")
    p.add_argument("--history-dir", help="default: <repo>/alert-history")
    p.add_argument("--rules-dir", help="default: <repo>/alerting/rules if it exists; '' for no rule map")
    p.add_argument("--state", help="default: <repo>/.grafana-sync/state.json if it exists")
    p.add_argument("--from", dest="frm", help="keep rows with time >= this (ms, s, YYYY-MM-DD, RFC3339)")
    p.add_argument("--to", help="keep rows with time <= this; also the export end")
    p.add_argument("--org-id", type=int, default=1)
    p.add_argument("-o", "--output", required=True)
    a = p.parse_args()

    t0 = time.time()
    hist = a.history_dir or os.path.join(a.repo, "alert-history")
    rules_dir = a.rules_dir if a.rules_dir is not None else os.path.join(a.repo, "alerting", "rules")
    state = a.state if a.state is not None else os.path.join(a.repo, ".grafana-sync", "state.json")
    frm = parse_time(a.frm) if a.frm else None
    to = parse_time(a.to) if a.to else None

    rules = load_rules(rules_dir) if rules_dir and os.path.isdir(rules_dir) else {}
    if not rules:
        log("rules: none (rule map empty; titles and labels come from annotation text)")

    cursor = None
    if state and os.path.isfile(state):
        cursor = json.load(open(state, encoding="utf-8")).get("history", {}).get("cursorMs")
        log(f"state: history.cursorMs = {cursor} ({iso(cursor) if cursor else '-'})")

    files = sorted(glob.glob(os.path.join(hist, "*", "*", "*.jsonl")))
    if not files:
        sys.exit(f"no day files under {hist}")
    by_id, stats = {}, {"files": 0, "files_skipped_by_range": 0, "lines": 0, "dup_identical": 0,
                        "dup_conflicting": 0, "no_id": 0, "out_of_range": 0, "wrong_day_file": 0}
    for f in files:
        ds = day_start(f)
        if ds is not None and ((frm is not None and ds + DAY_MS <= frm) or (to is not None and ds > to)):
            stats["files_skipped_by_range"] += 1
            continue
        stats["files"] += 1
        with open(f, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                stats["lines"] += 1
                r = json.loads(line)
                rid = r.get("id")
                if not isinstance(rid, int):
                    stats["no_id"] += 1
                    log(f"WARN {f}:{n}: row without integer id skipped")
                    continue
                t = r.get("time")
                if ds is not None and not (ds <= t < ds + DAY_MS):
                    stats["wrong_day_file"] += 1
                if (frm is not None and t < frm) or (to is not None and t > to):
                    stats["out_of_range"] += 1
                    continue
                row = {k: r.get(k) for k in KEEP}
                old = by_id.get(rid)
                if old is None:
                    by_id[rid] = row
                elif identity(old) == identity(row):
                    stats["dup_identical"] += 1
                else:
                    stats["dup_conflicting"] += 1
                    log(f"WARN id={rid}: second copy with different content in {f}:{n}, first copy kept")
    anns = [by_id[k] for k in sorted(by_id)]
    if not anns:
        sys.exit("no rows in the selected range")
    tmin = min(r["time"] for r in anns)
    tmax = max(r["time"] for r in anns)
    d_from = frm if frm is not None else tmin
    if to is not None:
        d_to = to
    elif cursor and cursor >= tmax:
        d_to = cursor
    else:
        d_to = tmax
    dump = {
        "format": "gah2prom-dump/1",
        "grafana_url": "git:" + os.path.abspath(a.repo),
        "org_id": a.org_id,
        "from": d_from,
        "to": d_to,
        "exported_at": int(time.time() * 1000),
        "rules": dict(sorted(rules.items(), key=lambda kv: int(kv[0]))),
        "annotations": anns,
    }
    with open(a.output, "w") as fh:
        json.dump(dump, fh, indent=1, sort_keys=True)
    mapped = sum(1 for r in anns if str(r["alertId"]) in rules)
    stats.update({
        "annotations": len(anns), "distinct_alert_ids": len({r["alertId"] for r in anns}),
        "annotations_with_rule_in_map": mapped, "rules_in_map": len(rules),
        "oldest_row": iso(tmin), "newest_row": iso(tmax), "dump_from": iso(d_from), "dump_to": iso(d_to),
        "output_bytes": os.path.getsize(a.output), "seconds": round(time.time() - t0, 1),
        "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024,
    })
    log(json.dumps(stats, indent=1))
    log(f"wrote {a.output}: {len(anns)} annotations")


if __name__ == "__main__":
    main()
