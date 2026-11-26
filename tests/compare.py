#!/usr/bin/env python3
"""Compare test-run timings between two sets of runs (medians per measurement).

  tests/compare.py tests/build/runs/before-*.json -- tests/build/runs/after-*.json

Prints each test's numeric measurements (latency, poll, hover, refresh
percentiles, stall count) as the median of the runs on each side, and the
pass/fail counts, so a change can be checked for speed it lost.
"""
import json, statistics, sys

args = sys.argv[1:]
if "--" not in args:
    sys.exit(__doc__)
cut = args.index("--")
sides = {"before": args[:cut], "after": args[cut + 1:]}


def numbers(prefix, value, out):
    if isinstance(value, bool) or value is None:
        return
    if isinstance(value, (int, float)):
        out[prefix] = float(value)
    elif isinstance(value, dict):
        for k, v in value.items():
            if k != "limitMs":
                numbers(f"{prefix}.{k}" if prefix else k, v, out)


table, status = {}, {}
for side, files in sides.items():
    for path in files:
        run = json.load(open(path))
        for r in run["results"]:
            status.setdefault((side, r["id"]), []).append(r["status"])
            found = {}
            numbers("", r["metrics"], found)
            for name, v in found.items():
                table.setdefault((r["id"], r["name"], name), {}).setdefault(side, []).append(v)

for side, files in sides.items():
    counts = {}
    for (s, _), sts in status.items():
        if s == side:
            for st in sts:
                counts[st] = counts.get(st, 0) + 1
    print(f"{side}: {len(files)} runs, " + ", ".join(f"{n} {k}" for k, n in sorted(counts.items())))
    bad = sorted({tid for (s, tid), sts in status.items() if s == side and any(x != "PASS" for x in sts)})
    if bad:
        print(f"  not passing every run: " + ", ".join(
            f"{tid} {'/'.join(status[(side, tid)])}" for tid in bad))

print(f"\n{'test':<28}{'measurement':<26}{'before':>10}{'after':>10}")
for (tid, name, metric), sides_ in sorted(table.items()):
    b, a = sides_.get("before"), sides_.get("after")
    med = lambda xs: f"{statistics.median(xs):.1f}" if xs else "-"
    print(f"{tid + ' ' + name:<28.28}{metric:<26.26}{med(b):>10}{med(a):>10}")
