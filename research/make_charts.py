#!/usr/bin/env python3
"""Render the README charts (light and dark SVG) from the confirmatory run log.

Usage: python3 research/make_charts.py   (writes docs/img/*.svg)
"""
import csv
import statistics as st
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "research/results/run2-confirmatory.csv"
OUT = ROOT / "docs/img"

THEMES = {
    "light": dict(surface="#fcfcfb", text="#0b0b0b", text2="#52514e", muted="#8a8985",
                  grid="#e6e5e1", axis="#c9c8c2", s1="#2a78d6", s2="#eb6834", band="#f0efec"),
    "dark": dict(surface="#1a1a19", text="#f0efec", text2="#c3c2b7", muted="#8f8e88",
                 grid="#2c2c2a", axis="#4a4a46", s1="#3987e5", s2="#d95926", band="#262624"),
}
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
W, H = 760, 380
M = dict(l=64, r=150, t=58, b=52)  # right margin holds direct labels


def load():
    rows = [r for r in csv.DictReader(l for l in open(LOG) if not l.startswith("#"))]
    for r in rows:
        r["t"] = float(r["t"]); r["rpm"] = int(r["rpm"])
    return rows


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


class Chart:
    def __init__(self, theme, title, subtitle, xr, yr):
        self.c = THEMES[theme]
        self.xr, self.yr = xr, yr
        self.parts = []
        c = self.c
        self.add(f'<rect width="{W}" height="{H}" rx="8" fill="{c["surface"]}"/>')
        self.add(f'<text x="{M["l"]}" y="26" font-size="16" font-weight="600" fill="{c["text"]}">{esc(title)}</text>')
        self.add(f'<text x="{M["l"]}" y="45" font-size="12" fill="{c["text2"]}">{esc(subtitle)}</text>')

    def add(self, s):
        self.parts.append(s)

    def X(self, v):
        a, b = self.xr
        return M["l"] + (v - a) / (b - a) * (W - M["l"] - M["r"])

    def Y(self, v):
        a, b = self.yr
        return H - M["b"] - (v - a) / (b - a) * (H - M["t"] - M["b"])

    def axes(self, xticks, yticks, xlabel, ylabel, xfmt=str):
        c = self.c
        for v in yticks:
            y = self.Y(v)
            self.add(f'<line x1="{M["l"]}" x2="{W - M["r"]}" y1="{y:.1f}" y2="{y:.1f}" stroke="{c["grid"]}" stroke-width="1"/>')
            self.add(f'<text x="{M["l"] - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end" fill="{c["text2"]}">{v:,}</text>')
        y0 = H - M["b"]
        self.add(f'<line x1="{M["l"]}" x2="{W - M["r"]}" y1="{y0}" y2="{y0}" stroke="{c["axis"]}" stroke-width="1"/>')
        for v in xticks:
            x = self.X(v)
            self.add(f'<text x="{x:.1f}" y="{y0 + 18}" font-size="11" text-anchor="middle" fill="{c["text2"]}">{xfmt(v)}</text>')
        self.add(f'<text x="{(M["l"] + W - M["r"]) / 2:.1f}" y="{H - 10}" font-size="11" text-anchor="middle" fill="{c["text2"]}">{esc(xlabel)}</text>')
        self.add(f'<text transform="translate(16 {(M["t"] + H - M["b"]) / 2:.1f}) rotate(-90)" font-size="11" text-anchor="middle" fill="{c["text2"]}">{esc(ylabel)}</text>')

    def line(self, pts, color, dash=None):
        d = " ".join(f'{"M" if i == 0 else "L"}{self.X(x):.1f},{self.Y(y):.1f}' for i, (x, y) in enumerate(pts))
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"{da}/>')

    def dot(self, x, y, color, r=4.5, hollow=False):
        c = self.c
        fill = c["surface"] if hollow else color
        self.add(f'<circle cx="{self.X(x):.1f}" cy="{self.Y(y):.1f}" r="{r}" fill="{fill}" stroke="{color if hollow else c["surface"]}" stroke-width="2"/>')

    def label(self, x, y, text, color_text, swatch=None, dash=None, anchor="start", size=12, weight="400"):
        c = self.c
        px, py = (x, y) if isinstance(x, float) and x > 1 and swatch == "px" else (self.X(x), self.Y(y))
        if swatch and swatch != "px":
            da = f' stroke-dasharray="{dash}"' if dash else ""
            self.add(f'<line x1="{px + 6:.1f}" x2="{px + 20:.1f}" y1="{py:.1f}" y2="{py:.1f}" stroke="{swatch}" stroke-width="2"{da}/>')
            px += 24
        self.add(f'<text x="{px:.1f}" y="{py + 4:.1f}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" fill="{color_text}">{esc(text)}</text>')

    def svg(self, desc):
        body = "\n".join(self.parts)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
                f'font-family="{FONT}" role="img" aria-label="{esc(desc)}">\n<title>{esc(desc)}</title>\n{body}\n</svg>\n')


def dose_response(rows, theme):
    """Mean hold RPM (7-12 s after the write) per min-duty setting, both sweeps."""
    holds = defaultdict(list)
    for s in {r["step"] for r in rows if r["step"] != "end"}:
        rs = [r for r in rows if r["step"] == s]
        v = int(rs[0]["value"], 16)
        h = [r["rpm"] for r in rs if r["phase"] == "hold" and 7 <= r["t"] <= 12]
        holds[v].append(st.mean(h))
    duties = sorted(holds)
    ch = Chart(theme, "Fan speed follows the minimum duty set from Linux",
               "Mean speed 7–12 s after each write · 14 steps in two sweeps · NUC11TNHi7",
               (37, 83), (2800, 4600))
    c = ch.c
    # plateau band
    y1, y2 = ch.Y(3000), ch.Y(2920)
    ch.add(f'<rect x="{ch.X(38):.1f}" y="{y1:.1f}" width="{ch.X(47) - ch.X(38):.1f}" height="{y2 - y1:.1f}" rx="4" fill="{c["band"]}"/>')
    ch.axes([40, 45, 50, 60, 70, 80], [2800, 3200, 3600, 4000, 4400], "Minimum duty written to the EC (%)", "Fan speed (RPM)", lambda v: f"{v} %")
    means = [(v, st.mean(holds[v])) for v in duties]
    ch.line(means, c["s1"])
    for v in duties:
        for y in holds[v]:
            ch.dot(v, y, c["s1"], r=4, hollow=True)
    for v, y in means:
        ch.dot(v, y, c["s1"])
    for v, y in means:
        if v in (50, 80):
            ch.add(f'<text x="{ch.X(v) + (10 if v == 50 else -10):.1f}" y="{ch.Y(y) + (18 if v == 50 else -12):.1f}" font-size="11" '
                   f'text-anchor="{"start" if v == 50 else "end"}" fill="{c["text"]}">{y:,.0f} RPM{" (BIOS default)" if v == 50 else ""}</text>')
    ch.add(f'<text x="{ch.X(42.5):.1f}" y="{ch.Y(2920) + 16:.1f}" font-size="11" text-anchor="middle" fill="{c["text2"]}">plateau ≈ 2,960 RPM</text>')
    lx = W - M["r"] + 8
    ch.add(f'<circle cx="{lx + 8}" cy="{M["t"] + 10}" r="4.5" fill="{c["s1"]}" stroke="{c["surface"]}" stroke-width="2"/>')
    ch.add(f'<text x="{lx + 20}" y="{M["t"] + 14}" font-size="12" fill="{c["text"]}">mean</text>')
    ch.add(f'<circle cx="{lx + 8}" cy="{M["t"] + 32}" r="4" fill="{c["surface"]}" stroke="{c["s1"]}" stroke-width="2"/>')
    ch.add(f'<text x="{lx + 20}" y="{M["t"] + 36}" font-size="12" fill="{c["text"]}">each step</text>')
    return ch.svg("Line chart: fan speed rises from about 2,960 RPM at 40–45 % minimum duty to about 4,380 RPM at 80 %; 50 % (BIOS default) gives about 3,120 RPM.")


def time_course(rows, theme):
    """RPM around a write: last 10 s of baseline, 12 s hold, 20 s after restore."""
    steps = {"4": "80 %", "3": "40 %", "1": "sham (50 → 50 %)"}
    order = sorted({int(r["step"]) for r in rows if r["step"] != "end"})
    ch = Chart(theme, "The EC applies a write within seconds",
               "Fan speed around a single write, sampled 4× per second · restore at 12 s",
               (-10, 32), (2800, 4600))
    c = ch.c
    hx1, hx2 = ch.X(0), ch.X(12)
    ch.add(f'<rect x="{hx1:.1f}" y="{M["t"]}" width="{hx2 - hx1:.1f}" height="{H - M["t"] - M["b"]}" fill="{c["band"]}"/>')
    ch.add(f'<text x="{(hx1 + hx2) / 2:.1f}" y="{M["t"] + 14}" font-size="11" text-anchor="middle" fill="{c["text2"]}">new value held</text>')
    ch.axes([-10, 0, 10, 20, 30], [2800, 3200, 3600, 4000, 4400], "Seconds since the write", "Fan speed (RPM)", lambda v: f"{v:+d}" if v else "0")
    colors = {"4": (c["s1"], None), "3": (c["s2"], None), "1": (c["muted"], "5 4")}
    ends = {}
    for s, name in steps.items():
        rs = [r for r in rows if r["step"] == s]
        nxt = [r for r in rows if r["step"] == str(order[order.index(int(s)) + 1])]
        pts = [(r["t"] - 60.0 - max(0, max(x["t"] for x in rs if x["phase"] == "base") - 60.0), r["rpm"])
               for r in rs if r["phase"] == "base" and r["t"] >= max(x["t"] for x in rs if x["phase"] == "base") - 10]
        base_end = max(x["t"] for x in rs if x["phase"] == "base")
        pts = [(r["t"] - base_end, r["rpm"]) for r in rs if r["phase"] == "base" and r["t"] >= base_end - 10]
        hold = [r for r in rs if r["phase"] == "hold"]
        hold_end = max(r["t"] for r in hold)
        pts += [(r["t"], r["rpm"]) for r in hold]
        pts += [(hold_end + r["t"], r["rpm"]) for r in nxt if r["phase"] == "base" and r["t"] <= 32 - hold_end]
        col, dash = colors[s]
        ch.line(pts, col, dash)
        ends[s] = pts[-1]
    # direct labels at the right edge, nudged apart
    ys = {s: ch.Y(y) for s, (x, y) in ends.items()}
    placed = sorted(ys.items(), key=lambda kv: kv[1])
    last = -1e9
    for s, y in placed:
        y = max(y, last + 16)
        last = y
        col, dash = colors[s]
        lx = W - M["r"] + 4
        da = f' stroke-dasharray="{dash}"' if dash else ""
        ch.add(f'<line x1="{lx}" x2="{lx + 14}" y1="{y:.1f}" y2="{y:.1f}" stroke="{col}" stroke-width="2"{da}/>')
        ch.add(f'<text x="{lx + 18}" y="{y + 4:.1f}" font-size="12" fill="{c["text"]}">{esc(steps[s])}</text>')
    return ch.svg("Line chart: after writing 80 % the fan rises from about 3,150 to 4,380 RPM within 2 seconds; after writing 40 % it falls to about 2,960 RPM within about 7 seconds; a sham write causes no change. All return toward baseline after the restore.")


def main():
    rows = load()
    OUT.mkdir(parents=True, exist_ok=True)
    for theme in THEMES:
        (OUT / f"dose-response-{theme}.svg").write_text(dose_response(rows, theme))
        (OUT / f"time-course-{theme}.svg").write_text(time_course(rows, theme))
    print("wrote", sorted(p.name for p in OUT.glob("*.svg")))


if __name__ == "__main__":
    main()
