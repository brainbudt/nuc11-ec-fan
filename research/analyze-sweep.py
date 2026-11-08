#!/usr/bin/env python3
"""Evaluate a fan-sweep-test.sh log against criteria fixed before the run.

Plan: the 14 steps in PLAN (two sweeps, the second in reverse order).
Windows (real seconds since phase start): base t >= 40, hold t >= 7 (hold lasts >= 12 s), end t >= 30.
Rationale (from exploratory run 1): the hold window starts after RPM had settled (~1-3 s after
raising, ~7 s after lowering). Temperatures may still drift later in the window (run 1 saw the
first shift 9-18 s after a write); C4 enforces temperature overlap regardless.

Temperature-matched delta (md) per step: group base-window and hold-window samples by
the exact pair (CPU temp, EC source-4 temp), i.e. both fan-record-1 temperature sources.
For every pair present in both windows, take mean(hold rpm) - mean(base rpm);
md = average of those differences weighted by the hold sample count in each pair.
A pure temperature response therefore gives md ~ 0. Raw deltas are printed for reference.

C1 sham steps (0x32):     |md| < 80 RPM
C2 active steps:           md has the sign of (value - 0x32) and |md| >= 120 RPM
C3 dose response:          within each sweep, md strictly increases with value
                           (the sweep's two sham steps are averaged)
C4 temperature overlap:    every step has >= 3 hold samples in matched temperature pairs
C5 replication:            each active value: both sweeps' md have the same sign and
                           the larger/smaller ratio is <= 2
C6 bytes and restore:      every base/end byte is 0x32, every hold byte is its step value,
                           and mean end rpm is within 150 RPM of step 1 base
C7 completeness:           exact plan sequence; base window >= 6 samples, hold >= 4,
                           each phase reaches its duration; end window >= 3 samples
                           reaching t >= 40; no '#' failure lines
Usage: analyze-sweep.py LOG
"""
import csv
import statistics as st
import sys
from collections import defaultdict

OLD = 0x32
PLAN = [0x32, 0x3C, 0x28, 0x50, 0x32, 0x46, 0x2D, 0x2D, 0x46, 0x32, 0x50, 0x28, 0x3C, 0x32]
SWEEP = 7

lines = open(sys.argv[1]).read().splitlines()
failures = [l for l in lines if l.startswith("#")]
rows = list(csv.DictReader(l for l in lines if not l.startswith("#") and not l.startswith("abort")))
for r in rows:
    r["t"] = float(r["t"]); r["rpm"] = int(r["rpm"]); r["cpu_c"] = int(r["cpu_c"])
    r["src4_c"] = None if r["src4_c"] == "NA" else int(r["src4_c"])


def matched_delta(base, hold):
    cells = defaultdict(lambda: ([], []))
    for r in base:
        cells[(r["cpu_c"], r["src4_c"])][0].append(r["rpm"])
    for r in hold:
        cells[(r["cpu_c"], r["src4_c"])][1].append(r["rpm"])
    both = [(b, h) for b, h in cells.values() if b and h]
    n = sum(len(h) for _, h in both)
    if n == 0:
        return None, 0
    return sum(len(h) * (st.mean(h) - st.mean(b)) for b, h in both) / n, n


seq = []
for r in rows:
    if r["step"] != "end" and (not seq or seq[-1][0] != r["step"]):
        seq.append((r["step"], int(r["value"], 16)))
complete = [v for _, v in seq] == PLAN and [s for s, _ in seq] == [str(i + 1) for i in range(len(PLAN))]
complete = complete and not failures

res = []
for s, v in seq:
    rs = [r for r in rows if r["step"] == s]
    if any(int(r["value"], 16) != v for r in rs):
        complete = False
    b = [r for r in rs if r["phase"] == "base" and r["t"] >= 40]
    h = [r for r in rs if r["phase"] == "hold" and r["t"] >= 7]
    if (len(b) < 6 or len(h) < 4 or max(r["t"] for r in rs if r["phase"] == "base") < 60
            or max((r["t"] for r in rs if r["phase"] == "hold"), default=0) < 12
            or any(r["src4_c"] is None for r in b + h)):
        complete = False
        res.append(dict(s=s, v=v, ok=False)); continue
    md, n = matched_delta(b, h)
    res.append(dict(s=s, v=v, ok=True, base=st.mean(x["rpm"] for x in b),
                    raw=st.mean(x["rpm"] for x in h) - st.mean(x["rpm"] for x in b), md=md, n=n))

end = [r for r in rows if r["step"] == "end"]
end_w = [r for r in end if r["t"] >= 30]
complete = complete and len(end_w) >= 3 and max((r["t"] for r in end), default=0) >= 40

print("step value  base_rpm  raw_delta  matched_delta  matched_n")
for x in res:
    if x["ok"]:
        md = "   n/a" if x["md"] is None else f"{x['md']:6.0f}"
        print(f"{x['s']:>4} {x['v']:3d}%  {x['base']:7.0f}  {x['raw']:9.0f}  {md:>13}  {x['n']:9d}")
    else:
        print(f"{x['s']:>4} {x['v']:3d}%  incomplete")

ok = {"C7 completeness": complete}
if complete:
    ok["C4 temperature overlap (>=3 matched hold samples)"] = all(x["n"] >= 3 for x in res)
if len(ok) == 2 and all(ok.values()):
    ok["C1 sham |md|<80"] = all(abs(x["md"]) < 80 for x in res if x["v"] == OLD)
    ok["C2 direction and |md|>=120"] = all(
        (x["md"] > 0) == (x["v"] > OLD) and abs(x["md"]) >= 120 for x in res if x["v"] != OLD)
    mono = True
    for sw in (res[:SWEEP], res[SWEEP:]):
        by_v = defaultdict(list)
        for x in sw:
            by_v[x["v"]].append(x["md"])
        mds = [st.mean(by_v[v]) for v in sorted(by_v)]
        mono = mono and all(a < b for a, b in zip(mds, mds[1:]))
    ok["C3 monotonic per sweep"] = mono
    rep = True
    for v in sorted({x["v"] for x in res if x["v"] != OLD}):
        d = [x["md"] for x in res if x["v"] == v]
        rep = rep and len(d) == 2 and (d[0] > 0) == (d[1] > 0) and max(map(abs, d)) <= 2 * min(map(abs, d))
    ok["C5 replication"] = rep
    bytes_ok = all(r["byte"] == "0x32" for r in rows if r["phase"] in ("base", "end")) and all(
        int(r["byte"], 16) == int(r["value"], 16) for r in rows if r["phase"] == "hold")
    end_rpm = st.mean(r["rpm"] for r in end_w)
    ok["C6 bytes and restore"] = bytes_ok and abs(end_rpm - res[0]["base"]) <= 150
    print(f"end rpm = {end_rpm:.0f}")
for k, v in ok.items():
    print(f"{'PASS' if v else 'FAIL'}  {k}")
for f in failures:
    print("log:", f)
sys.exit(0 if len(ok) == 7 and all(ok.values()) else 1)
