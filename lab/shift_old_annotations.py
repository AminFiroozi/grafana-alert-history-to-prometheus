#!/usr/bin/env python3
"""Lab-only: copy the first N minutes of real alert annotations in env1's
grafana.db back in time (e.g. -6h, -30h, -20d) so the export/backfill path is
tested against data older than the Prometheus head and older than retention.
Usage: shift_old_annotations.py grafana.db <window_minutes> <shift_hours>..."""
import sqlite3, sys
db, window_min, shifts = sys.argv[1], int(sys.argv[2]), [float(x) for x in sys.argv[3:]]
c = sqlite3.connect(db)
cols = [r[1] for r in c.execute("PRAGMA table_info(annotation)") if r[1] != "id"]
t0 = c.execute("SELECT MIN(epoch) FROM annotation WHERE alert_id > 0").fetchone()[0]
t1 = t0 + window_min * 60000
for h in shifts:
    off = int(h * 3600000)
    sel = ", ".join(f"{k} - {off}" if k in ("epoch", "epoch_end") else k for k in cols)
    n = c.execute(f"INSERT INTO annotation ({', '.join(cols)}) SELECT {sel} FROM annotation "
                  f"WHERE alert_id > 0 AND epoch >= ? AND epoch < ?", (t0, t1)).rowcount
    print(f"shift -{h}h: inserted {n} rows (source window {t0}..{t1})")
c.commit()
