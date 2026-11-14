#!/usr/bin/env python3
"""Generate the Parasol solution map SVGs from tools/diagrams/solution-map.yaml.

Writes content/modules/ROOT/assets/images/solution-map/:
  solution-map.svg           the full map, nothing highlighted
  <slug>.svg                 one per module in /modules.yaml, that module's ids lit
                             (module level only: per-exercise maps were tried and dropped,
                             2026-11-14 — noise on every step, and a chore to keep in sync)

Run from the repo root:  python3 tools/diagrams/solution-map.py
Output is deterministic, so re-running is a no-op unless the spec or this file changed.
Fails (exit 1) on a spec that drifted from /modules.yaml, an unknown id, a tile no module
uses, or a label too wide for its box.
"""
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import yaml  # PyYAML; the only non-stdlib import

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "tools/diagrams/solution-map.yaml"
OUT = ROOT / "content/modules/ROOT/assets/images/solution-map"

# ── palette (Red Hat) ─────────────────────────────────────────────────────────────────────
RED, INK = "#EE0000", "#151515"
FONT = "'Red Hat Text','Red Hat Display',sans-serif"
HEAD_FONT = "'Red Hat Display','Red Hat Text',sans-serif"
STYLE = {  # state -> (fill, stroke, stroke-width, label colour, label weight, sub colour)
    "norm": ("#FFFFFF", "#B8BBBE", 1.2, INK, 600, "#6A6E73"),
    "hi":   ("#FFFFFF", RED,       2.6, INK, 700, "#4D4D4D"),
    "dim":  ("#FAFAFA", "#E0E0E0", 1.0, "#8A8D90", 600, "#A3A6A9"),
}
EDGE = {"norm": ("#6A6E73", 1.6), "hi": (RED, 2.6), "dim": ("#CFD1D3", 1.4)}

# ── geometry (viewBox units; 1000 wide, so 15 units = 12 px at an 800 px content width) ──
W, M, GAP = 1000, 16, 10              # width, outer margin, gap between group panels
COLW = (W - 2 * M - 4 * GAP) / 5      # five grid columns shared by every band
PAD = 8                               # group panel padding around its tiles
TW, TH, TG = COLW - 2 * PAD, 48, 8    # tile width, height, vertical gap
GHEAD = 32                            # group header height
TOP_Y = 66                            # top band (build & deliver)
APP_Y = TOP_Y + GHEAD + 2 * TH + TG + 10 + 12
BW, BH, AG, RG = 152, 52, 36, 32      # app box width/height, column gap (arrows), row gap
APP_X = M + 14
C5_X, C5_W = APP_X + 4 * BW + 3 * AG + 30, W - M - 14 - (APP_X + 4 * BW + 3 * AG + 30)
APP_H = 16 + 3 * BH + 2 * RG + 16
BOT_Y = APP_Y + APP_H + 12            # bottom band (run & operate)
MIN_FONT = 15                         # nothing smaller: 12 px at 800 px


def text_w(s, size, bold=False):
    """Rough rendered width of s; good enough to catch a label that will not fit."""
    w = 0.0
    for ch in s:
        if ch in "iljI.,:;'|!·":
            w += 0.27
        elif ch in "ftr()- ":
            w += 0.34
        elif ch in "mwMW":
            w += 0.86
        elif ch.isupper() or ch == "&":
            w += 0.66
        else:
            w += 0.55
    return w * size * (1.07 if bold else 1.0)


def fits(s, size, room, bold=False):
    if text_w(s, size, bold) > room:
        sys.exit(f"solution-map: label {s!r} ({text_w(s, size, bold):.0f}) does not fit in {room:.0f}")


def text(x, y, s, size, fill, weight=400, anchor="middle", family=FONT, spacing=None):
    assert size >= MIN_FONT, s
    ls = f' letter-spacing="{spacing}"' if spacing else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{ls}>{escape(s)}</text>')


def box(x, y, w, h, label, sub, state, size=15.5, rx=8, dashed=False):
    fill, stroke, sw, lc, lw, sc = STYLE[state]
    fits(label, size, w - 14, bold=True)
    fits(sub, 15, w - 14)
    dash = ' stroke-dasharray="6 4"' if dashed else ""
    cx = x + w / 2
    return [
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h}" rx="{rx}" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="{sw}"{dash}/>',
        text(cx, y + h / 2 - 3, label, size, lc, lw),
        text(cx, y + h / 2 + 15, sub, 15, sc),
    ]


def panel_head(x, y, title, state, room):
    """Group header: caps title, with a red marker when the group holds a lit tile."""
    colour = "#8A8D90" if state == "dim" else INK
    out = []
    if state == "hi":
        out.append(f'<rect x="{x:.1f}" y="{y - 10:.1f}" width="8" height="8" rx="1.5" fill="{RED}"/>')
        x += 14
    fits(title.upper(), 15, room - 14, bold=True)
    out.append(text(x, y, title.upper(), 15, colour, 700, "start", spacing="0.4"))
    return out


def load():
    spec = yaml.safe_load(SPEC.read_text())
    catalog = yaml.safe_load((ROOT / "modules.yaml").read_text())["modules"]
    titles = {m["slug"]: m["title"] for m in catalog}
    tiles = {t["id"]: t for g in spec["groups"] for t in g["tiles"]}
    comps = {c["id"]: c for c in spec["components"]}
    ids = set(tiles) | set(comps)
    errors = []
    if set(spec["modules"]) != set(titles):
        errors.append(f"modules: spec vs modules.yaml differ: {sorted(set(spec['modules']) ^ set(titles))}")
    for name, lit in spec["modules"].items():
        if not lit:
            errors.append(f"{name}: lights nothing")
        errors += [f"{name}: unknown id {i!r}" for i in lit if i not in ids]
    for slug, lit in spec["modules"].items():
        if not set(lit) & set(tiles):
            errors.append(f"{slug}: maps to no capability tile")
    used = {i for lit in spec["modules"].values() for i in lit}
    errors += [f"tile {t!r} is used by no module" for t in tiles if t not in used]
    for a, b in spec["edges"]:
        ca, cb = comps[a], comps[b]
        if abs(ca["col"] - cb["col"]) + abs(ca["row"] - cb["row"]) != 1:
            errors.append(f"edge {a}>{b} must join neighbouring cells")
    if errors:
        sys.exit("solution-map: spec errors:\n  " + "\n  ".join(errors))
    return spec, titles, tiles, comps


def comp_rect(c):
    x, w = (C5_X, C5_W) if c["col"] == 5 else (APP_X + (c["col"] - 1) * (BW + AG), BW)
    return x, APP_Y + 16 + (c["row"] - 1) * (BH + RG), w, BH


def render(spec, comps, lit, here=None):
    """lit = set of ids to highlight (None = the plain full map); here = header caption."""
    def state(i):
        return "norm" if lit is None else ("hi" if i in lit else "dim")

    def group_state(member_ids):
        return "norm" if lit is None else ("hi" if set(member_ids) & lit else "dim")

    bot_h = GHEAD + 6 * TH + 5 * TG + 10
    H = int(BOT_Y + bot_h + M)
    # width/height as well as viewBox: an <img> of an SVG with only a viewBox has no intrinsic size and
    # renders 0x0 when the page gives no width. AsciiDoc's width= still overrides these.
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
         f'aria-labelledby="sm-title sm-desc">']
    title = "Parasol solution map" + (f" — {here}" if here else "")
    names = {**{t["id"]: t["label"] for g in spec["groups"] for t in g["tiles"]},
             **{c["id"]: c["label"] for c in spec["components"]}}
    desc = ("The Parasol claims application — web front end, claims API, claims database, fraud, "
            "notifications, serverless premium calculator, event broker and consumer, batch jobs and "
            "a model endpoint — with the platform capabilities around it, grouped as build, deliver, "
            "run, connect, observe, secure and govern, and resilience.")
    if lit:
        desc += " Highlighted here: " + ", ".join(names[i] for i in sorted(lit, key=list(names).index)) + "."
    o.append(f'<title id="sm-title">{escape(title)}</title><desc id="sm-desc">{escape(desc)}</desc>')
    o.append("<defs>" + "".join(
        f'<marker id="a-{s}" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="9" markerHeight="9" '
        f'markerUnits="userSpaceOnUse" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
        for s, (c, _) in EDGE.items()) + "</defs>")
    # card
    o.append(f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="18" fill="#FFFFFF" stroke="#D2D2D2" stroke-width="1.5"/>')
    # header
    o.append(text(M + 8, 42, "Parasol solution map", 23, INK, 700, "start", HEAD_FONT))
    hx = M + 8 + text_w("Parasol solution map", 23, True) + 22
    if here:
        pill = text_w("YOU ARE HERE", 15, True) + 10 + 24
        o.append(f'<rect x="{hx:.1f}" y="22" width="{pill:.1f}" height="28" rx="14" fill="{RED}"/>')
        o.append(text(hx + pill / 2, 41, "YOU ARE HERE", 15, "#FFFFFF", 700, spacing="0.8"))
        fits(here, 17, W - M - 8 - (hx + pill + 12), bold=True)
        o.append(text(hx + pill + 12, 42, here, 17, INK, 600, "start"))
    else:
        o.append(text(hx, 41, "The application you build, and the platform capabilities around it",
                      15, "#6A6E73", 400, "start"))

    # capability groups
    col = {"top": 0, "bottom": 0}
    for g in spec["groups"]:
        span, band = g["span"], g["band"]
        gx = M + col[band] * (COLW + GAP)
        gy = TOP_Y if band == "top" else BOT_Y
        gw = span * COLW + (span - 1) * GAP
        rows = -(-len(g["tiles"]) // span)
        gh = (GHEAD + 2 * TH + TG + 10) if band == "top" else (
            bot_h if g["id"] != "g-resilience" else GHEAD + rows * TH + (rows - 1) * TG + 10)
        o.append(f'<rect x="{gx:.1f}" y="{gy}" width="{gw:.1f}" height="{gh}" rx="12" fill="#F2F2F2"/>')
        o += panel_head(gx + PAD + 2, gy + 22, g["title"], group_state(t["id"] for t in g["tiles"]), gw - 2 * PAD)
        for k, t in enumerate(g["tiles"]):
            tx = gx + PAD + (k % span) * (COLW + GAP)
            ty = gy + GHEAD + (k // span) * (TH + TG)
            o += box(tx, ty, TW, TH, t["label"], t["sub"], state(t["id"]))
        if g["id"] == "g-resilience":
            o += legend(gx, gy + gh + GAP, gw, BOT_Y + bot_h - (gy + gh + GAP), lit is not None)
        col[band] += span

    # application panel
    o.append(f'<rect x="{M}" y="{APP_Y}" width="{W - 2 * M}" height="{APP_H}" rx="14" fill="#FFFFFF" '
             f'stroke="{INK}" stroke-width="1.5"/>')
    o += panel_head(APP_X + 4, APP_Y + 34, "The Parasol application", group_state(comps), 2 * (BW + AG))
    o.append(text(APP_X + 4, APP_Y + 58, "What the labs deploy and connect", 15, "#6A6E73", 400, "start"))
    for a, b in spec["edges"]:
        s = "norm" if lit is None else ("hi" if {a, b} <= lit else "dim")
        o.append(arrow(comp_rect(comps[a]), comp_rect(comps[b]), s))
    for c in spec["components"]:
        x, y, w, h = comp_rect(c)
        o += box(x, y, w, h, c["label"], c["sub"], state(c["id"]), size=16,
                 rx=h / 2 if c.get("pill") else 9, dashed=c.get("external", False))
    o.append("</svg>")
    return "\n".join(o) + "\n"


def arrow(ra, rb, s):
    """Straight arrow between two neighbouring boxes, tip landing on b's border."""
    colour, sw = EDGE[s]
    (ax, ay, aw, ah), (bx, by, bw, bh) = ra, rb
    if abs(ay - by) < 1:  # same row
        y = ay + ah / 2
        x1, x2 = (ax + aw, bx - 10) if bx > ax else (ax, bx + bw + 10)
        d = f"M{x1:.1f},{y:.1f} H{x2:.1f}"
    else:  # same column
        x = ax + aw / 2
        y1, y2 = (ay + ah, by - 10) if by > ay else (ay, by + bh + 10)
        d = f"M{x:.1f},{y1:.1f} V{y2:.1f}"
    return f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{sw}" marker-end="url(#a-{s})"/>'


def legend(x, y, w, h, variant):
    o = [f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="12" fill="#FFFFFF" '
         f'stroke="#D2D2D2" stroke-width="1"/>',
         text(x + PAD + 2, y + 24, "LEGEND", 15, INK, 700, "start", spacing="0.6")]
    items = ([("hi", "You build or", "use this here"), ("dim", "Elsewhere in", "the course")] if variant else [])
    items += [("arrow", "Calls or", "connects to"), ("dashed", "Outside the", "cluster")]
    for k, (kind, l1, l2) in enumerate(items):
        iy = y + 38 + k * 44
        sx = x + PAD + 4
        if kind == "arrow":
            o.append(f'<path d="M{sx:.1f},{iy + 16:.1f} H{sx + 22:.1f}" stroke="{EDGE["norm"][0]}" '
                     f'stroke-width="1.6" marker-end="url(#a-norm)"/>')
        else:
            fill, stroke, sw = STYLE[kind if kind != "dashed" else "norm"][:3]
            dash = ' stroke-dasharray="5 3"' if kind == "dashed" else ""
            o.append(f'<rect x="{sx:.1f}" y="{iy + 4:.1f}" width="32" height="24" rx="5" fill="{fill}" '
                     f'stroke="{stroke}" stroke-width="{sw}"{dash}/>')
        for line, dy in ((l1, 13), (l2, 31)):
            fits(line, 15, w - (sx - x) - 44 - PAD)
            o.append(text(sx + 44, iy + dy, line, 15, "#4D4D4D", 400, "start"))
    return o


def main():
    spec, titles, _tiles, comps = load()
    OUT.mkdir(parents=True, exist_ok=True)
    files = {"solution-map.svg": render(spec, comps, None)}
    for slug, lit in spec["modules"].items():
        files[f"{slug}.svg"] = render(spec, comps, set(lit), titles[slug])
    changed = 0
    for name, svg in files.items():
        p = OUT / name
        if not p.exists() or p.read_text() != svg:
            p.write_text(svg)
            changed += 1
    print(f"solution-map: {len(files)} SVGs in {OUT.relative_to(ROOT)} ({changed} changed)")


if __name__ == "__main__":
    main()
