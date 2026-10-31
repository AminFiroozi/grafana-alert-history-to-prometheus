#!/usr/bin/env python3
"""Fallback path: build a gah2prom dump from a CSV exported straight from Grafana's
SQL database, for when /api/annotations cannot be used.

Run this query on env1's Grafana DB (works on SQLite, MySQL, PostgreSQL) and save
the result as CSV with a header row:

  SELECT a.id, a.alert_id, a.epoch, a.prev_state, a.new_state, a.text,
         r.uid AS rule_uid, r.title AS rule_title
  FROM annotation a LEFT JOIN alert_rule r ON r.id = a.alert_id
  WHERE a.alert_id > 0 AND a.org_id = 1
    AND a.epoch BETWEEN <from_ms> AND <to_ms>
  ORDER BY a.epoch, a.id;

Usage: csv_to_dump.py annotations.csv --from <ms> --to <ms> -o dump.json
"""
import argparse, csv, json, time

p = argparse.ArgumentParser()
p.add_argument("csv")
p.add_argument("--from", dest="frm", type=int, required=True, help="epoch ms used in the WHERE clause")
p.add_argument("--to", type=int, required=True, help="epoch ms used in the WHERE clause (export end)")
p.add_argument("--org-id", type=int, default=1)
p.add_argument("-o", "--output", required=True)
a = p.parse_args()

rules, anns = {}, []
with open(a.csv, newline="") as f:
    for r in csv.DictReader(f):
        rid = int(r["alert_id"])
        if r.get("rule_uid"):
            rules[str(rid)] = {"uid": r["rule_uid"], "title": r["rule_title"]}
        anns.append({"id": int(r["id"]), "alertId": rid, "alertName": r.get("rule_title") or "",
                     "time": int(r["epoch"]), "timeEnd": int(r["epoch"]),
                     "prevState": r["prev_state"], "newState": r["new_state"], "text": r["text"]})
json.dump({"format": "gah2prom-dump/1", "grafana_url": "sql", "org_id": a.org_id, "from": a.frm, "to": a.to,
           "exported_at": int(time.time() * 1000), "rules": rules,
           "annotations": sorted(anns, key=lambda x: x["id"])}, open(a.output, "w"), indent=1, sort_keys=True)
print(f"wrote {a.output}: {len(anns)} annotations, {len(rules)} rules")
