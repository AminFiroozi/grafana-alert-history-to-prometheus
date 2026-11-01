#!/usr/bin/env python3
"""gah2prom: Grafana unified-alerting state history -> Prometheus (OpenMetrics backfill).

Python 3 standard library only.

Subcommands
  export   Pull alert state history from Grafana (/api/annotations?type=alert)
           plus the rule list (id -> uid/title) into one JSON dump file.
  convert  Turn a dump into an OpenMetrics file with explicit timestamps, ready
           for `promtool tsdb create-blocks-from openmetrics`.
  verify   Rebuild transitions from Prometheus raw samples and diff them
           against the transitions in the dump. Exit code 1 on any mismatch.

Data model of the generated series (same label names as Grafana 12.1's
"prometheus" state-history backend, so old and new history can be queried
side by side):

  ALERTS_HISTORY{alertname, alertstate, grafana_alertstate, grafana_rule_uid,
                 <instance labels>, source="<source>"}  1   while in that state
                                                          0   once, at the exact
                                                              end of the interval

  alertstate          firing | pending   (Prometheus ALERTS semantics)
  grafana_alertstate  alerting | pending | nodata | error | recovering
  Normal is not emitted (no series), like Grafana's own backend.

Always filter with `== 1` (or `> 0`) in queries: the trailing 0 sample is the
exact end marker, because promtool cannot write Prometheus stale markers.
"""

import argparse
import base64
import json
import math
import os
import resource
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict

EMITTING = {"alerting": "firing", "pending": "pending", "nodata": "firing",
            "error": "firing", "recovering": "firing"}
KNOWN_STATES = set(EMITTING) | {"normal"}
LABEL_KEY_RE = re.compile(r"^[^,=\s][^=]*$")
SPLIT_RE = re.compile(r", (?=[^,=\s][^=,]*=)")
INVALID_LABEL_CHARS = re.compile(r"[^a-zA-Z0-9_]")


# --------------------------------------------------------------------------- utils
def log(msg):
    print(msg, file=sys.stderr, flush=True)


def parse_duration(s):
    m = re.fullmatch(r"(\d+)(ms|s|m|h|d|w)", s.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"bad duration: {s}")
    n, u = int(m.group(1)), m.group(2)
    return n * {"ms": 1, "s": 1000, "m": 60000, "h": 3600000, "d": 86400000, "w": 604800000}[u]


def parse_time(s):
    """Accept epoch ms, epoch s, RFC3339 (UTC 'Z'), 'now', or 'now-<duration>'."""
    s = s.strip()
    now = int(time.time() * 1000)
    if s == "now":
        return now
    if s.startswith("now-"):
        return now - parse_duration(s[4:])
    if re.fullmatch(r"\d+", s):
        v = int(s)
        return v if v > 10**11 else v * 1000
    import datetime
    dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp() * 1000)


def iso(ms):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + ".%03dZ" % (ms % 1000)


def sanitize_label_name(k):
    k = INVALID_LABEL_CHARS.sub("_", k)
    if not k or k[0].isdigit():
        k = "_" + k
    return k


def om_escape(v):
    return v.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class Http:
    def __init__(self, base, token=None, user=None, password=None, insecure=False, org_id=None, timeout=60,
                 ca_cert=None, extra_headers=None):
        self.base = base.rstrip("/")
        self.headers = {"Accept": "application/json"}
        for h in extra_headers or []:
            k, sep, v = h.partition(":")
            if not sep or not k.strip():
                raise SystemExit(f"bad --header {h!r}: expected 'Name: value'")
            self.headers[k.strip()] = v.strip()
        if token:
            self.headers["Authorization"] = "Bearer " + token
        elif user:
            self.headers["Authorization"] = "Basic " + base64.b64encode(f"{user}:{password or ''}".encode()).decode()
        if org_id:
            self.headers["X-Grafana-Org-Id"] = str(org_id)
        if insecure:
            self.ctx = ssl._create_unverified_context()
        elif ca_cert:
            self.ctx = ssl.create_default_context(cafile=ca_cert)
        else:
            self.ctx = None
        self.timeout = timeout

    def get(self, path, params=None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        for attempt in range(5):
            try:
                req = urllib.request.Request(url, headers=self.headers)
                with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                    return json.loads(r.read().decode())
            except urllib.error.HTTPError as e:
                if e.code < 500 or attempt == 4:
                    raise RuntimeError(f"GET {url} -> HTTP {e.code}: {e.read()[:300]!r}")
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt == 4:
                    raise RuntimeError(f"GET {url} failed: {e}")
            time.sleep(2 ** attempt)


# --------------------------------------------------------------------------- export
def fetch_rules(http):
    """Return {rule_id(int): {"uid":..., "title":...}}."""
    rules = {}
    try:
        for r in http.get("/api/v1/provisioning/alert-rules"):
            rules[int(r["id"])] = {"uid": r["uid"], "title": r["title"]}
        return rules
    except RuntimeError as e:
        log(f"provisioning API unavailable ({e}); falling back to ruler API")
    data = http.get("/api/ruler/grafana/api/v1/rules")
    for _folder, groups in data.items():
        for g in groups:
            for r in g.get("rules", []):
                ga = r.get("grafana_alert", {})
                if "id" in ga:
                    rules[int(ga["id"])] = {"uid": ga["uid"], "title": ga["title"]}
    return rules


def fetch_annotations(http, frm, to, limit):
    """/api/annotations has no offset paging: it returns the newest `limit` rows
    (ORDER BY epoch_end DESC). If a window comes back full, split it in two."""
    out = {}
    stack = [(frm, to)]
    calls = 0
    while stack:
        a, b = stack.pop()
        rows = http.get("/api/annotations", {"type": "alert", "from": a, "to": b, "limit": limit})
        calls += 1
        if len(rows) >= limit:
            if b - a <= 1:
                raise RuntimeError(f"more than {limit} annotations at {a}..{b}; raise --limit")
            mid = (a + b) // 2
            stack.append((a, mid))
            stack.append((mid + 1, b))
            continue
        for r in rows:
            out[r["id"]] = r
    log(f"annotations: {len(out)} rows in {calls} API calls")
    return [out[k] for k in sorted(out)]


def env_headers(var):
    """Extra headers from an environment variable, one 'Name: value' per line (keeps secrets off the command line)."""
    return [h for h in os.environ.get(var, "").splitlines() if h.strip()]


def cmd_export(a):
    http = Http(a.url, a.token or os.environ.get("GAH_TOKEN"), a.user or os.environ.get("GAH_USER"),
                a.password or os.environ.get("GAH_PASSWORD"), a.insecure, a.org_id,
                ca_cert=a.ca_cert, extra_headers=env_headers("GAH_HEADERS") + a.header)
    frm, to = parse_time(a.frm), parse_time(a.to)
    rules = fetch_rules(http)
    log(f"rules: {len(rules)}")
    rows = fetch_annotations(http, max(frm, 1), to, a.limit)
    keep = ("id", "alertId", "alertName", "time", "timeEnd", "prevState", "newState", "text", "data", "dashboardUID", "panelId")
    dump = {
        "format": "gah2prom-dump/1",
        "grafana_url": a.url,
        "org_id": a.org_id or 1,
        "from": frm,
        "to": to,
        "exported_at": int(time.time() * 1000),
        "rules": {str(k): v for k, v in sorted(rules.items())},
        "annotations": [{k: r.get(k) for k in keep} for r in rows],
    }
    with open(a.output, "w") as f:
        json.dump(dump, f, indent=1, sort_keys=True)
    log(f"wrote {a.output}: {len(rows)} annotations, range {iso(frm)} .. {iso(to)}")


# --------------------------------------------------------------------------- parsing
def base_state(formatted):
    """'Alerting (Error)' -> 'alerting'; 'Normal (MissingSeries)' -> 'normal'."""
    s = (formatted or "").split(" ", 1)[0].strip().lower()
    return s


def parse_labels(text, title):
    """Annotation text is `<title> {k=v, k=v} - <values>` (historian/annotation.go
    BuildAnnotationTextAndData, data.Labels.String(): keys sorted, ', ' joined).
    Returns (labels_dict, ok)."""
    if title and text.startswith(title + " {"):
        body = text[len(title) + 2:]
    else:
        i = text.find(" {")
        if i < 0:
            return {}, False
        body = text[i + 2:]
    j = body.rfind("} - ")
    if j < 0:
        return {}, False
    inner = body[:j]
    if inner == "":
        return {}, True
    parts = SPLIT_RE.split(inner)
    labels, keys = {}, []
    for p in parts:
        if "=" not in p:
            return {}, False
        k, v = p.split("=", 1)
        if not LABEL_KEY_RE.match(k):
            return {}, False
        labels[k] = v
        keys.append(k)
    ok = keys == sorted(keys) and len(set(keys)) == len(keys)
    return labels, ok


def build_transitions(dump, source, source_label):
    """Return (instances, stats). instances: key -> {"labels": {...}, "events": [(ts, state, id)], "prev0": state}"""
    rules = {int(k): v for k, v in dump.get("rules", {}).items()}
    inst = {}
    stats = defaultdict(int)
    for r in sorted(dump["annotations"], key=lambda r: (r["time"], r["id"])):
        stats["annotations"] += 1
        rule = rules.get(int(r["alertId"]))
        title = (rule or {}).get("title") or r.get("alertName") or ""
        labels, ok = parse_labels(r["text"], title)
        if not ok:
            stats["label_parse_ambiguous"] += 1
            log(f"WARN annotation id={r['id']}: labels not cleanly parseable from text: {r['text'][:200]!r}")
        new, prev = base_state(r["newState"]), base_state(r["prevState"])
        for s in (new, prev):
            if s not in KNOWN_STATES:
                stats["unknown_state"] += 1
                log(f"WARN annotation id={r['id']}: unknown state {s!r}")
        out = {}
        for k, v in labels.items():
            if v == "":
                # Prometheus has no empty-valued labels (empty = absent): keep the instance key
                # identical to the series Prometheus stores, so verify compares like with like
                stats["empty_label_values_dropped"] += 1
                continue
            sk = sanitize_label_name(k)
            if sk in ("alertstate", "grafana_alertstate", "grafana_rule_uid", source_label, "__name__"):
                stats["reserved_label_overridden"] += 1
                continue
            out[sk] = v
        out.setdefault("alertname", title)
        out["grafana_rule_uid"] = (rule or {}).get("uid") or f"unknown-rule-id-{r['alertId']}"
        if rule is None:
            stats["rule_not_found"] += 1
        out[source_label] = source
        key = tuple(sorted(out.items()))
        d = inst.setdefault(key, {"labels": out, "events": [], "prev0": prev,
                                  "alert_id": int(r["alertId"]), "rule_known": rule is not None})
        d["events"].append((int(r["time"]), new, r["id"]))
    return inst, stats


def intervals_for(d, frm, to, leading):
    """Collapse events into [(start, end_or_None, state)] for emitting states.
    end None = still open at `to`."""
    evs = d["events"]
    cur, cur_start = None, None
    res = []
    if leading and d["prev0"] in EMITTING:
        cur, cur_start = d["prev0"], frm
    for ts, st, _id in evs:
        if st == cur:
            continue  # reason-only change (e.g. Alerting -> Alerting (Error)); state unchanged
        if cur in EMITTING and ts > cur_start:  # empty leading interval (start == first event) is dropped
            res.append((cur_start, ts, cur))
        cur, cur_start = st, ts
    if cur in EMITTING:
        res.append((cur_start, None, cur))
    return res


def lead_start(dump):
    """Start of the 'leading' interval (state already active before the first
    annotation of an instance). Never earlier than the oldest annotation in the
    dump, so a dump with --from 1 does not produce samples back to 1970."""
    first = min((int(r["time"]) for r in dump["annotations"]), default=dump["from"])
    return max(dump["from"], first)


def instance_ends(dump, inst, to, deleted_rule_end, stats=None):
    """Export end per instance. Grafana does not record a state-history row when a rule
    is deleted (v12.0.0 schedule/alert_rule.go:357-360 -> state.Manager.DeleteStateByRuleUID,
    which never calls the historian), so the last state of a deleted rule looks open
    forever. With deleted_rule_end='last-event', an instance of a rule that is not in
    the rule map stops at the newest annotation of that rule (any instance): the last
    moment the rule is known to have existed. Only applied when the map is non-empty."""
    ends = {}
    if deleted_rule_end != "last-event" or not dump.get("rules"):
        if deleted_rule_end == "last-event" and stats is not None:
            log("WARN --deleted-rule-end last-event ignored: the dump has no rule map")
        return ends
    last = defaultdict(int)
    for r in dump["annotations"]:
        last[int(r["alertId"])] = max(last[int(r["alertId"])], int(r["time"]))
    for key, d in inst.items():
        if not d["rule_known"]:
            ends[key] = min(to, last[d["alert_id"]])
    if stats is not None:
        stats["instances_of_deleted_rules_capped"] = len(ends)
    return ends


class OMWriter:
    """One OpenMetrics file, or one file per aligned time window (`split_ms`), so that
    promtool parses each file for one block window only (promtool re-reads its whole
    input once per block window, cmd/promtool/backfill.go createBlocks)."""

    def __init__(self, output, metric, split_ms=None):
        self.output, self.metric, self.split_ms = output, metric, split_ms
        self.files = {}
        if split_ms:
            os.makedirs(output, exist_ok=True)
        else:
            self._open(None, output)

    def _open(self, w, path):
        f = open(path, "w", buffering=1 << 20)
        f.write(f"# HELP {self.metric} Grafana alert state history backfilled from annotations (1 = in state, 0 = end marker)\n")
        f.write(f"# TYPE {self.metric} gauge\n")
        self.files[w] = [f, path, 0]
        return self.files[w]

    def write(self, lbl, ts, v):
        if self.split_ms:
            w = ts // self.split_ms
            e = self.files.get(w) or self._open(w, os.path.join(self.output, "%s.om" % iso(w * self.split_ms).replace(":", "")))
        else:
            e = self.files[None]
        e[0].write(f"{self.metric}{{{lbl}}} {'1' if v == 1.0 else '0'} {ts // 1000}.{ts % 1000:03d}\n")
        e[2] += 1

    def close(self):
        for w in sorted(self.files, key=lambda k: -1 if k is None else k):
            f, path, n = self.files[w]
            f.write("# EOF\n")
            f.close()
            if self.split_ms:
                log(f"  {path}: {n} samples, {os.path.getsize(path)} bytes")


# --------------------------------------------------------------------------- convert
def cmd_convert(a):
    t0 = time.time()
    dump = json.load(open(a.input))
    frm, to = lead_start(dump), dump["to"]
    if a.until:
        to = min(to, parse_time(a.until))
    step = parse_duration(a.step)
    if step >= 300000:
        log("WARN --step >= 5m: instant queries see gaps inside intervals with the default lookback delta (5m)")
    inst, stats = build_transitions(dump, a.source, a.source_label)
    ends = instance_ends(dump, inst, to, a.deleted_rule_end, stats)
    # series key -> intervals in input order; samples are generated per series at write time,
    # so memory holds one series' samples at a time, not the whole file.
    series = {}
    for key, d in inst.items():
        inst_to = ends.get(key, to)
        for start, end, st in intervals_for(d, frm, to, a.leading):
            lbl = dict(d["labels"])
            lbl["alertstate"] = EMITTING[st]
            lbl["grafana_alertstate"] = st
            for k, v in a.extra_label:
                lbl[k] = v
            sk = tuple(sorted(lbl.items()))
            series.setdefault(sk, []).append((start, end, end if end is not None else inst_to + 1))
            stats["intervals"] += 1
            stats["intervals_open"] += end is None
            if end is None and key in ends and inst_to < to:
                stats["open_intervals_cut_at_deleted_rule_last_event"] += 1
    n, mint = 0, None
    out = OMWriter(a.output, a.metric, parse_duration(a.split) if a.split else None)
    for sk in sorted(series):
        pts = {}
        for start, end, stop in series[sk]:
            # exact start, then an epoch-aligned grid (identical across re-runs)
            pts[start] = 1.0
            t = (start // step + 1) * step
            while t < stop:
                pts[t] = 1.0
                t += step
            if end is not None and a.end_marker == "zero":
                if pts.get(end) != 1.0:  # a new interval of the same series starting at `end` wins
                    pts[end] = 0.0
        lbl = ",".join(f'{k}="{om_escape(v)}"' for k, v in sk)
        first = min(pts)
        mint = first if mint is None else min(mint, first)
        for ts in sorted(pts):
            out.write(lbl, ts, pts[ts])
            n += 1
    out.close()
    stats["series"] = len(series)
    stats["samples"] = n
    stats["instances"] = len(inst)
    log(json.dumps(dict(stats), sort_keys=True))
    log(f"wrote {a.output}: {len(series)} series, {n} samples, "
        f"{iso(mint) if mint else '-'} .. {iso(to)}")
    log(f"convert took {time.time() - t0:.1f}s, peak RSS {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024} MB")


# --------------------------------------------------------------------------- verify
def source_transitions(dump, source, source_label, leading, until=None, deleted_rule_end="export"):
    frm, to = lead_start(dump), dump["to"]
    if until:
        to = min(to, until)
    inst, _ = build_transitions(dump, source, source_label)
    instance_ends(dump, inst, to, deleted_rule_end)  # ends do not change starts/ends of intervals, only sample spans
    out = set()
    leading_n = 0
    for key, d in inst.items():
        for start, end, st in intervals_for(d, frm, to, leading):
            out.add((key, start, st))
            if leading and start == frm and d["prev0"] == st:
                leading_n += 1  # synthetic start at --from (state known from first prevState)
            if end is not None:
                out.add((key, end, "end:" + st))
    return out, leading_n


def prom_transitions(prom, metric, source, source_label, frm, to):
    sel = f'{metric}{{{source_label}="{source}"}}'
    series = prom.get("/api/v1/series", {"match[]": sel, "start": frm / 1000 - 1, "end": to / 1000 + 1})["data"]
    out = set()
    nsamples = 0
    rng = int((to - frm) / 1000) + 3600
    for s in series:
        m = ",".join(f'{k}="{om_escape(v)}"' for k, v in sorted(s.items()) if k != "__name__")
        r = prom.get("/api/v1/query", {"query": f"{metric}{{{m}}}[{rng}s]", "time": to / 1000 + 1})
        for res in r["data"]["result"]:
            lbl = res["metric"]
            if {k: v for k, v in lbl.items() if k != "__name__"} != {k: v for k, v in s.items() if k != "__name__"}:
                continue  # label matchers also select series with more labels; each series is read once
            st = lbl.get("grafana_alertstate")
            key = tuple(sorted((k, v) for k, v in lbl.items() if k not in ("__name__", "alertstate", "grafana_alertstate")))
            prev = None
            for ts_s, val in res["values"]:
                ts = int(round(float(ts_s) * 1000))
                v = float(val)
                nsamples += 1
                if v == 1.0 and prev != 1.0:
                    out.add((key, ts, st))
                elif v == 0.0 and prev == 1.0:
                    out.add((key, ts, "end:" + st))
                prev = v
    return out, len(series), nsamples


def cmd_verify(a):
    dump = json.load(open(a.input))
    until = parse_time(a.until) if a.until else None
    src, leading_n = source_transitions(dump, a.source, a.source_label, a.leading, until, a.deleted_rule_end)
    prom = Http(a.prometheus, a.prom_token or os.environ.get("GAH_PROM_TOKEN"),
                a.prom_user or os.environ.get("GAH_PROM_USER"),
                a.prom_password or os.environ.get("GAH_PROM_PASSWORD"), a.insecure,
                ca_cert=a.ca_cert, extra_headers=env_headers("GAH_PROM_HEADERS") + a.header)
    to = min(dump["to"], until) if until else dump["to"]
    got, nseries, nsamples = prom_transitions(prom, a.metric, a.source, a.source_label, dump["from"] - 86400000, to)
    if a.extra_label:  # convert --extra-label adds these labels to every series
        extra = dict(a.extra_label)
        src = {(tuple(sorted({**dict(k), **extra}.items())), ts, st) for k, ts, st in src}
    missing = sorted(src - got, key=lambda x: (x[1], x[0]))
    extra = sorted(got - src, key=lambda x: (x[1], x[0]))
    starts = sum(1 for x in src if not x[2].startswith("end:"))
    report = {
        "source_annotations": len(dump["annotations"]),
        "source_events": len(src),
        "source_interval_starts": starts,
        "source_interval_ends": len(src) - starts,
        "source_leading_starts_at_from": leading_n,
        "prometheus_series": nseries,
        "prometheus_samples_read": nsamples,
        "reconstructed_events": len(got),
        "matched": len(src & got),
        "missing_in_prometheus": len(missing),
        "unexpected_in_prometheus": len(extra),
    }
    print(json.dumps(report, indent=1))
    for tag, lst in (("MISSING", missing), ("EXTRA", extra)):
        for key, ts, st in lst[:50]:
            print(f"{tag} {iso(ts)} {st} {dict(key)}")
    sys.exit(1 if missing or extra else 0)


# --------------------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("export", help="export state history from Grafana")
    e.add_argument("--url", required=True, help="Grafana base URL, e.g. https://grafana.example")
    e.add_argument("--token", help="service account token (Bearer); default: env GAH_TOKEN")
    e.add_argument("--user", help="basic auth user; default: env GAH_USER")
    e.add_argument("--password", help="basic auth password; default: env GAH_PASSWORD")
    e.add_argument("--ca-cert", help="CA bundle (PEM) to verify the server certificate")
    e.add_argument("--header", action="append", default=[], metavar="'Name: value'",
                   help="extra HTTP header, repeatable (more can come from env GAH_HEADERS, one per line)")
    e.add_argument("--org-id", type=int)
    e.add_argument("--insecure", action="store_true", help="skip TLS verification")
    e.add_argument("--from", dest="frm", default="1", help="epoch ms/s, RFC3339 UTC, now-30d (default: 1 = everything)")
    e.add_argument("--to", default="now")
    e.add_argument("--limit", type=int, default=5000, help="rows per API call; windows that hit it are split")
    e.add_argument("-o", "--output", required=True)
    e.set_defaults(fn=cmd_export)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-i", "--input", required=True, help="dump file from `export`")
    common.add_argument("--metric", default="ALERTS_HISTORY")
    common.add_argument("--source", default="grafana-env1", help="value of the source label")
    common.add_argument("--source-label", default="source")
    common.add_argument("--no-leading", dest="leading", action="store_false",
                        help="do not emit the interval that was already open at --from (derived from the first prevState)")
    common.add_argument("--until", help="treat this time as the export end (default: dump 'to')")
    common.add_argument("--deleted-rule-end", choices=["export", "last-event"], default="export",
                        help="where a still-open interval of a rule missing from the rule map stops: at the export "
                             "end (default, as stored) or at that rule's newest annotation (Grafana writes no row "
                             "when a rule is deleted)")

    c = sub.add_parser("convert", parents=[common], help="dump -> OpenMetrics")
    c.add_argument("--step", default="15s", help="sample spacing inside an interval (<= env2 lookback delta, default 15s)")
    c.add_argument("--end-marker", choices=["zero", "none"], default="zero")
    c.add_argument("--extra-label", action="append", default=[], type=lambda s: tuple(s.split("=", 1)), metavar="K=V")
    c.add_argument("--split", metavar="DURATION",
                   help="write one file per epoch-aligned window of this length into the directory -o "
                        "(use the same value as promtool --max-block-duration, e.g. 486h)")
    c.add_argument("-o", "--output", required=True, help="OpenMetrics file, or a directory with --split")
    c.set_defaults(fn=cmd_convert)

    v = sub.add_parser("verify", parents=[common], help="diff dump transitions vs Prometheus")
    v.add_argument("--prometheus", required=True, help="env2 Prometheus base URL (may include a path prefix)")
    v.add_argument("--insecure", action="store_true", help="skip TLS verification of Prometheus")
    v.add_argument("--prom-token", help="Prometheus Bearer token; default: env GAH_PROM_TOKEN")
    v.add_argument("--prom-user", help="Prometheus basic auth user; default: env GAH_PROM_USER")
    v.add_argument("--prom-password", help="Prometheus basic auth password; default: env GAH_PROM_PASSWORD")
    v.add_argument("--ca-cert", help="CA bundle (PEM) to verify the Prometheus certificate")
    v.add_argument("--header", action="append", default=[], metavar="'Name: value'",
                   help="extra HTTP header, repeatable (more can come from env GAH_PROM_HEADERS, one per line)")
    v.add_argument("--extra-label", action="append", default=[], type=lambda s: tuple(s.split("=", 1)),
                   metavar="K=V", help="same value(s) as given to convert")
    v.set_defaults(fn=cmd_verify)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
