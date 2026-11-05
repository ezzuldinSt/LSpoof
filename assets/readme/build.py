#!/usr/bin/env python3
"""Builds the animated SVGs that README.md shows, from the screenshots in screens/.

    python assets/readme/build.py

The SVGs embed the screenshots, so they render on GitHub without loading anything else.
Screens are 540 x 1173 JPEGs of the picker with the status bar blacked out; the phone
frame draws its own. Taps are placed as fractions of the screen's width and height.
Animations are plain CSS (and SMIL for motion along a path), and stop under Reduce Motion.
"""
import base64
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCREENS = HERE / "screens"
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI Variable Display', 'Segoe UI', Inter, Roboto, 'Helvetica Neue', Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SCREEN_RATIO = 2868 / 1320


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def image_uri(name):
    return "data:image/jpeg;base64," + base64.b64encode((SCREENS / f"{name}.jpg").read_bytes()).decode()


def keyframes(name, total, stops):
    """stops: (seconds, css) pairs in time order; written as percentages of total."""
    frames = []
    last = -1.0
    for t, css in stops:
        p = max(0.0, min(100.0, t / total * 100.0))
        p = max(p, last + 0.001)  # strictly increasing
        last = p
        frames.append(f"{min(p, 100):.3f}%{{{css}}}")
    return f"@keyframes {name}{{{''.join(frames)}}}"


class Svg:
    def __init__(self, width, height, title, desc):
        self.width, self.height = width, height
        self.title, self.desc = title, desc
        self.defs, self.css, self.body = [], [], []
        self.loaded = set()

    def screen(self, name):
        if name not in self.loaded:
            self.loaded.add(name)
            self.defs.append(f'<image id="s-{name}" width="540" height="1173" preserveAspectRatio="xMidYMid slice" href="{image_uri(name)}"/>')
        return f"s-{name}"

    def animate(self, cls, total, stops, timing="linear"):
        self.css.append(keyframes(f"k-{cls}", total, stops))
        self.css.append(f".{cls}{{animation:k-{cls} {total}s {timing} infinite}}")

    def render(self):
        css = "".join(self.css)
        reduce = "@media (prefers-reduced-motion: reduce){*{animation:none !important}}"
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{self.width}" height="{self.height}" '
            f'viewBox="0 0 {self.width} {self.height}" role="img" aria-labelledby="t d">'
            f'<title id="t">{esc(self.title)}</title><desc id="d">{esc(self.desc)}</desc>'
            f'<style>text{{font-family:{FONT}}}.mono{{font-family:{MONO}}}.fb{{transform-box:fill-box;transform-origin:center}}'
            f'.fl{{transform-box:fill-box;transform-origin:0 50%}}{css}{reduce}</style>'
            f'<defs>{"".join(self.defs)}</defs>{"".join(self.body)}</svg>\n'
        )


def card_background(svg, accent, uid):
    w, h = svg.width, svg.height
    svg.defs.append(
        f'<linearGradient id="bg{uid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0f1629"/><stop offset=".55" stop-color="#0a0f1d"/><stop offset="1" stop-color="#0c1222"/></linearGradient>'
        f'<radialGradient id="glow{uid}" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="{accent}" stop-opacity=".34"/><stop offset="1" stop-color="{accent}" stop-opacity="0"/></radialGradient>'
        f'<pattern id="grid{uid}" width="56" height="56" patternUnits="userSpaceOnUse" patternTransform="rotate(-24)"><path d="M0 0H56M0 0V56" stroke="#94a3b8" stroke-opacity=".07" stroke-width="1.2"/></pattern>'
        f'<clipPath id="card{uid}"><rect width="{w}" height="{h}" rx="28"/></clipPath>'
    )
    svg.body.append(
        f'<g clip-path="url(#card{uid})"><rect width="{w}" height="{h}" fill="url(#bg{uid})"/><rect width="{w}" height="{h}" fill="url(#grid{uid})"/></g>'
        f'<rect x=".75" y=".75" width="{w - 1.5}" height="{h - 1.5}" rx="27.5" fill="none" stroke="#ffffff" stroke-opacity=".08" stroke-width="1.5"/>'
    )


def segments_for(slots):
    """Merges consecutive slots that show the same screen: [(name, first_slot, last_slot)]."""
    merged = []
    for i, slot in enumerate(slots):
        if merged and merged[-1][0] == slot["screen"]:
            merged[-1][2] = i
        else:
            merged.append([slot["screen"], i, i])
    return merged


def phone(svg, x, y, w, slots, slot_len, uid, glow=None):
    """A phone at screen origin (x, y), screen width w, cycling through slots."""
    h = round(w * SCREEN_RATIO, 1)
    total = slot_len * len(slots)
    b = round(w * 0.045, 1)
    fade = 0.45
    if glow:
        svg.body.append(f'<ellipse cx="{x + w / 2}" cy="{y + h / 2}" rx="{w * 1.05}" ry="{h * 0.62}" fill="url(#glow{glow})"/>')
    svg.defs.append(
        f'<clipPath id="scr{uid}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{w * 0.165:.1f}"/></clipPath>'
        f'<linearGradient id="rim{uid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b6272"/><stop offset=".5" stop-color="#1c1f27"/><stop offset="1" stop-color="#454b58"/></linearGradient>'
    )
    r_out = w * 0.165 + b
    svg.body.append(
        f'<rect x="{x - b - 3.5}" y="{y + h * 0.2}" width="4" height="{h * 0.055}" rx="2" fill="#2a2e37"/>'
        f'<rect x="{x - b - 3.5}" y="{y + h * 0.28}" width="4" height="{h * 0.09}" rx="2" fill="#2a2e37"/>'
        f'<rect x="{x - b - 3.5}" y="{y + h * 0.39}" width="4" height="{h * 0.09}" rx="2" fill="#2a2e37"/>'
        f'<rect x="{x + w + b - 0.5}" y="{y + h * 0.3}" width="4" height="{h * 0.13}" rx="2" fill="#2a2e37"/>'
        f'<rect x="{x - b}" y="{y - b}" width="{w + 2 * b}" height="{h + 2 * b}" rx="{r_out:.1f}" fill="#06070a" stroke="url(#rim{uid})" stroke-width="2.2"/>'
    )
    layers = []
    for i, (name, first, last) in enumerate(segments_for(slots)):
        ref = svg.screen(name)
        cls = f"sg{uid}-{i}"
        start, end = first * slot_len, (last + 1) * slot_len
        if i == 0:
            layers.append(f'<use href="#{ref}" xlink:href="#{ref}" transform="translate({x} {y}) scale({w / 540:.5f})"/>')
            continue
        if end >= total:
            stops = [(0, "opacity:0"), (start, "opacity:0"), (start + fade, "opacity:1"), (total - fade, "opacity:1"), (total, "opacity:0")]
        else:
            stops = [(0, "opacity:0"), (start, "opacity:0"), (start + fade, "opacity:1"), (end + fade, "opacity:1"), (end + fade + 0.02, "opacity:0"), (total, "opacity:0")]
        svg.animate(cls, total, stops)
        svg.css.append(f".{cls}{{opacity:0}}")
        layers.append(f'<use class="{cls}" href="#{ref}" xlink:href="#{ref}" transform="translate({x} {y}) scale({w / 540:.5f})"/>')
    svg.body.append(f'<g clip-path="url(#scr{uid})"><rect x="{x}" y="{y}" width="{w}" height="{h}" fill="#000"/>{"".join(layers)}</g>')
    # Status bar and Dynamic Island, drawn over the blacked-out screenshot status bar.
    s = w / 252
    sy = y + 25 * s
    svg.body.append(
        f'<rect x="{x + w / 2 - 40 * s}" y="{y + 9 * s}" width="{80 * s}" height="{23 * s}" rx="{11.5 * s}" fill="#000"/>'
        f'<text x="{x + 33 * s}" y="{sy}" font-size="{14.5 * s:.1f}" font-weight="600" fill="#fff">9:41</text>'
        + "".join(f'<rect x="{x + w - 78 * s + i * 4.4 * s:.1f}" y="{sy - (3 + i * 2.2) * s:.1f}" width="{3 * s:.1f}" height="{(3 + i * 2.2) * s:.1f}" rx=".8" fill="#fff"/>' for i in range(4))
        + f'<path d="M{x + w - 56 * s:.1f} {sy - 7 * s:.1f}a{9 * s:.1f} {9 * s:.1f} 0 0 1 {12 * s:.1f} 0M{x + w - 53.5 * s:.1f} {sy - 4 * s:.1f}a{5 * s:.1f} {5 * s:.1f} 0 0 1 {7 * s:.1f} 0" stroke="#fff" stroke-width="{1.8 * s:.1f}" fill="none" stroke-linecap="round"/>'
        f'<circle cx="{x + w - 50 * s:.1f}" cy="{sy - 1 * s:.1f}" r="{1.4 * s:.1f}" fill="#fff"/>'
        f'<rect x="{x + w - 38 * s:.1f}" y="{sy - 9.5 * s:.1f}" width="{21 * s:.1f}" height="{10 * s:.1f}" rx="{3 * s:.1f}" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="{1 * s:.1f}"/>'
        f'<rect x="{x + w - 36.5 * s:.1f}" y="{sy - 8 * s:.1f}" width="{15 * s:.1f}" height="{7 * s:.1f}" rx="{1.8 * s:.1f}" fill="#fff"/>'
        f'<rect x="{x + w - 16.3 * s:.1f}" y="{sy - 6 * s:.1f}" width="{1.6 * s:.1f}" height="{3.5 * s:.1f}" rx=".8" fill="#fff" fill-opacity=".5"/>'
    )
    # Taps.
    for k, slot in enumerate(slots):
        tap = slot.get("tap")
        if not tap:
            continue
        cx, cy = x + tap[0] * w, y + tap[1] * h
        t0 = k * slot_len + slot_len * slot.get("at", 0.42)
        ring, dot = f"rp{uid}-{k}", f"dt{uid}-{k}"
        svg.animate(ring, total, [(0, "opacity:0;transform:scale(.4)"), (t0, "opacity:0;transform:scale(.4)"), (t0 + 0.06, "opacity:.95;transform:scale(.45)"),
                                  (t0 + 0.85, "opacity:0;transform:scale(1.8)"), (total, "opacity:0;transform:scale(.4)")])
        svg.animate(dot, total, [(0, "opacity:0;transform:scale(.6)"), (t0 - 0.08, "opacity:0;transform:scale(.6)"), (t0 + 0.04, "opacity:.8;transform:scale(1)"),
                                 (t0 + 0.5, "opacity:.8;transform:scale(1)"), (t0 + 0.72, "opacity:0;transform:scale(.85)"), (total, "opacity:0;transform:scale(.6)")])
        svg.css.append(f".{ring},.{dot}{{opacity:0}}")
        svg.body.append(
            f'<circle class="{ring} fb" cx="{cx:.1f}" cy="{cy:.1f}" r="{22 * s:.1f}" fill="none" stroke="#fff" stroke-width="{2.6 * s:.1f}"/>'
            f'<circle class="{dot} fb" cx="{cx:.1f}" cy="{cy:.1f}" r="{12 * s:.1f}" fill="#fff" fill-opacity=".55" stroke="#fff" stroke-opacity=".9" stroke-width="1.5"/>'
        )
    return total


def guide(file, number, eyebrow, title, subtitle, accent, slots, slot_len=3.6):
    svg = Svg(960, 640, f"LSpoof guide: {title}", f"{subtitle} Steps: " + " ".join(f"{i + 1}. {' '.join(s['text'])}" for i, s in enumerate(slots)))
    uid = number
    card_background(svg, accent, uid)
    total = phone(svg, 96, 38, 260, slots, slot_len, uid, glow=uid)
    x0 = 446
    svg.body.append(
        f'<text x="{x0}" y="82" font-size="13.5" font-weight="700" letter-spacing="2.6" fill="{accent}">{esc(eyebrow.upper())}</text>'
        f'<text x="{x0}" y="128" font-size="40" font-weight="800" fill="#f5f7fb" letter-spacing="-.6">{esc(title)}</text>'
        f'<text x="{x0}" y="164" font-size="19" fill="#9aa5ba">{esc(subtitle)}</text>'
    )
    y = 230
    for k, slot in enumerate(slots):
        start, end = k * slot_len, (k + 1) * slot_len
        group, fill, bar = f"st{uid}-{k}", f"sf{uid}-{k}", f"pb{uid}-{k}"
        if k == 0:
            op = [(0, "opacity:1"), (end, "opacity:1"), (end + 0.3, "opacity:.38"), (total - 0.3, "opacity:.38"), (total, "opacity:1")]
        elif end >= total:
            op = [(0, "opacity:.38"), (start, "opacity:.38"), (start + 0.3, "opacity:1"), (total - 0.3, "opacity:1"), (total, "opacity:.38")]
        else:
            op = [(0, "opacity:.38"), (start, "opacity:.38"), (start + 0.3, "opacity:1"), (end, "opacity:1"), (end + 0.3, "opacity:.38"), (total, "opacity:.38")]
        svg.animate(group, total, op)
        svg.animate(fill, total, [(t, c.replace(".38", "0")) for t, c in op])
        bars = [(0, "transform:scaleX(0)"), (start, "transform:scaleX(0)"), (end - 0.02, "transform:scaleX(1)"), (end, "transform:scaleX(0)"), (total, "transform:scaleX(0)")]
        svg.animate(bar, total, bars)
        svg.css.append(f".{bar}{{transform:scaleX(0)}}.{fill}{{opacity:0}}")
        lines = slot["text"]
        text = "".join(f'<tspan x="{x0 + 56}" dy="{0 if i == 0 else 29}">{esc(line)}</tspan>' for i, line in enumerate(lines))
        svg.body.append(
            f'<g class="{group}">'
            f'<circle cx="{x0 + 19}" cy="{y + 1}" r="19" fill="none" stroke="{accent}" stroke-width="2"/>'
            f'<circle class="{fill}" cx="{x0 + 19}" cy="{y + 1}" r="19" fill="{accent}"/>'
            f'<text x="{x0 + 19}" y="{y + 8}" font-size="18" font-weight="800" fill="#fff" text-anchor="middle">{k + 1}</text>'
            f'<text x="{x0 + 56}" y="{y + 9}" font-size="22" font-weight="650" fill="#eef1f7">{text}</text>'
            f'<rect x="{x0 + 56}" y="{y + 26 + 29 * (len(lines) - 1)}" width="400" height="3" rx="1.5" fill="#ffffff" fill-opacity=".08"/>'
            f'<rect class="{bar} fl" x="{x0 + 56}" y="{y + 26 + 29 * (len(lines) - 1)}" width="400" height="3" rx="1.5" fill="{accent}"/>'
            f'</g>'
        )
        y += 74 + 29 * (len(lines) - 1) + 40
    svg.body.append(f'<text x="{x0}" y="606" font-size="14" fill="#6b7489">{esc(slots[0].get("footer", ""))}</text>')
    (HERE / file).write_text(svg.render(), encoding="utf-8")
    return file


def banner():
    svg = Svg(1280, 640, "LSpoof", "Set your iOS app's location to anywhere. A dylib for sideloaded apps: hold a spot, play realistic routes, save places and schedule it all.")
    uid = "b"
    accent = "#4f8bff"
    w, h = svg.width, svg.height
    svg.defs.append(
        '<linearGradient id="bgb" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#101a33"/><stop offset=".5" stop-color="#0a1020"/><stop offset="1" stop-color="#0d1226"/></linearGradient>'
        '<radialGradient id="glowb" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#4f8bff" stop-opacity=".42"/><stop offset="1" stop-color="#4f8bff" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="glowv" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#a855f7" stop-opacity=".28"/><stop offset="1" stop-color="#a855f7" stop-opacity="0"/></radialGradient>'
        '<linearGradient id="ink" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#8ec5ff"/><stop offset=".5" stop-color="#5b8cff"/><stop offset="1" stop-color="#b38cff"/></linearGradient>'
        '<linearGradient id="mark" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5aa2ff"/><stop offset="1" stop-color="#7c5cff"/></linearGradient>'
        '<linearGradient id="fadeL" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#0a1020" stop-opacity=".92"/><stop offset=".55" stop-color="#0a1020" stop-opacity=".55"/><stop offset="1" stop-color="#0a1020" stop-opacity="0"/></linearGradient>'
        '<pattern id="gridb" width="60" height="60" patternUnits="userSpaceOnUse" patternTransform="rotate(-24)"><path d="M0 0H60M0 0V60" stroke="#94a3b8" stroke-opacity=".075" stroke-width="1.2"/></pattern>'
        f'<clipPath id="cardb"><rect width="{w}" height="{h}" rx="32"/></clipPath>'
    )
    rng = random.Random(7)
    roads = []
    for _ in range(9):
        x1, y1 = rng.uniform(-100, 1300), rng.uniform(-50, 700)
        x2, y2 = x1 + rng.uniform(-500, 500), y1 + rng.uniform(-400, 400)
        roads.append(f'<path d="M{x1:.0f} {y1:.0f}Q{(x1 + x2) / 2 + rng.uniform(-120, 120):.0f} {(y1 + y2) / 2 + rng.uniform(-120, 120):.0f} {x2:.0f} {y2:.0f}" stroke="#a5b4fc" stroke-opacity=".07" stroke-width="{rng.choice([3, 5, 7])}" fill="none" stroke-linecap="round"/>')
    svg.body.append(
        f'<g clip-path="url(#cardb)"><rect width="{w}" height="{h}" fill="url(#bgb)"/><rect width="{w}" height="{h}" fill="url(#gridb)"/>'
        '<path d="M-40 250C200 330 330 160 560 230S900 420 1320 300" stroke="#1d3a72" stroke-opacity=".45" stroke-width="46" fill="none"/>'
        + "".join(roads)
        + '<ellipse cx="1060" cy="330" rx="330" ry="330" fill="url(#glowb)"/><ellipse cx="240" cy="60" rx="360" ry="220" fill="url(#glowv)"/>'
        f'<rect width="760" height="{h}" fill="url(#fadeL)"/></g>'
        f'<rect x=".75" y=".75" width="{w - 1.5}" height="{h - 1.5}" rx="31.5" fill="none" stroke="#fff" stroke-opacity=".09" stroke-width="1.5"/>'
    )
    # A route that draws itself in, with the location dot travelling along it.
    route = "M70 588C190 520 300 640 440 572S640 492 760 540S860 610 884 552"
    period = 9.0
    svg.animate("rt", period, [(0, "stroke-dashoffset:1000;opacity:1"), (period * 0.45, "stroke-dashoffset:0;opacity:1"), (period * 0.86, "stroke-dashoffset:0;opacity:1"),
                               (period * 0.97, "stroke-dashoffset:0;opacity:0"), (period, "stroke-dashoffset:1000;opacity:0")])
    svg.animate("rd", period, [(0, "opacity:1"), (period * 0.86, "opacity:1"), (period * 0.97, "opacity:0"), (period, "opacity:0")])
    svg.animate("pulse", 2.4, [(0, "transform:scale(.4);opacity:.9"), (2.4, "transform:scale(2.6);opacity:0")])
    svg.body.append(
        f'<path d="{route}" stroke="#4f8bff" stroke-opacity=".18" stroke-width="10" fill="none" stroke-linecap="round" stroke-dasharray="2 14"/>'
        f'<path class="rt" d="{route}" pathLength="1000" stroke="url(#ink)" stroke-width="6" fill="none" stroke-linecap="round" stroke-dasharray="1000"/>'
        '<circle cx="70" cy="588" r="9" fill="#22c55e" stroke="#0a1020" stroke-width="3"/>'
        '<circle class="pulse fb" cx="884" cy="552" r="16" fill="none" stroke="#f87171" stroke-width="3"/>'
        '<path d="M884 562c-10-12-15-20-15-27a15 15 0 0 1 30 0c0 7-5 15-15 27z" fill="#ef4444" stroke="#0a1020" stroke-width="2.5"/><circle cx="884" cy="535" r="5.5" fill="#fff"/>'
        '<g class="rd"><circle r="14" fill="#4f8bff" fill-opacity=".25"/><circle r="8.5" fill="#4f8bff" stroke="#fff" stroke-width="3"/>'
        f'<animateMotion dur="{period}s" repeatCount="indefinite" keyPoints="0;1;1" keyTimes="0;.45;1" calcMode="linear" path="{route}"/></g>'
    )
    # Title block.
    svg.body.append(
        '<rect x="88" y="78" width="84" height="84" rx="22" fill="url(#mark)"/>'
        '<rect x="88.75" y="78.75" width="82.5" height="82.5" rx="21.5" fill="none" stroke="#fff" stroke-opacity=".25" stroke-width="1.5"/>'
        '<path d="M150 98 106 117.5l20.5 6 6 20.5z" fill="#fff" stroke="#fff" stroke-width="3.5" stroke-linejoin="round"/>'
        '<text x="194" y="150" font-size="92" font-weight="800" letter-spacing="-2.5" fill="#f7f9ff">LSpoof</text>'
        '<text x="90" y="236" font-size="35" font-weight="600" fill="#dfe6f3" letter-spacing="-.3">Set your iOS app’s location to</text>'
    )
    words = ["Tokyo.", "Paris.", "New York.", "anywhere."]
    each, total = 2.6, 2.6 * len(words)
    for j, word in enumerate(words):
        # Each word slides in, holds, and has left before the next one arrives.
        s = j * each
        stops = [(0, "opacity:0;transform:translateY(28px)"), (s, "opacity:0;transform:translateY(28px)"), (s + 0.4, "opacity:1;transform:translateY(0)"),
                 (s + each - 0.4, "opacity:1;transform:translateY(0)"), (s + each, "opacity:0;transform:translateY(-28px)"), (total, "opacity:0;transform:translateY(-28px)")]
        if j == 0:
            stops = [(0, "opacity:1;transform:translateY(0)"), (each - 0.4, "opacity:1;transform:translateY(0)"), (each, "opacity:0;transform:translateY(-28px)"),
                     (total - 0.4, "opacity:0;transform:translateY(28px)"), (total, "opacity:1;transform:translateY(0)")]
        svg.animate(f"w{j}", total, stops, "ease-in-out")
        if j:
            svg.css.append(f".w{j}{{opacity:0}}")
        svg.body.append(f'<text class="w{j}" x="88" y="310" font-size="66" font-weight="800" letter-spacing="-1.5" fill="url(#ink)">{esc(word)}</text>')
    svg.body.append(
        '<text x="90" y="368" font-size="21" fill="#9aa5ba">A dylib for sideloaded apps. Hold a spot, play realistic routes,</text>'
        '<text x="90" y="398" font-size="21" fill="#9aa5ba">save places and schedule it all, right inside the app.</text>'
    )
    px = 90
    for label, color in [("Hold a spot", "#4f8bff"), ("Routes &amp; stops", "#34d399"), ("Map links", "#22d3ee"), ("Schedules", "#a78bfa")]:
        width = len(label.replace("&amp;", "&")) * 9.4 + 50
        svg.body.append(
            f'<rect x="{px}" y="430" width="{width:.0f}" height="40" rx="20" fill="#fff" fill-opacity=".055" stroke="#fff" stroke-opacity=".12"/>'
            f'<circle cx="{px + 20}" cy="450" r="5" fill="{color}"/>'
            f'<text x="{px + 33}" y="456" font-size="16.5" font-weight="600" fill="#dfe6f3">{label}</text>'
        )
        px += width + 12
    # Phone with the three workspaces.
    slots = [{"screen": "location"}, {"screen": "route"}, {"screen": "saved"}]
    phone(svg, 960, 40, 252, slots, 3.4, uid, glow=None)
    # Floating cards beside the phone.
    svg.animate("fa", 6, [(0, "transform:translateY(0)"), (3, "transform:translateY(-7px)"), (6, "transform:translateY(0)")], "ease-in-out")
    svg.animate("fc", 7, [(0, "transform:translateY(-4px)"), (3.5, "transform:translateY(5px)"), (7, "transform:translateY(-4px)")], "ease-in-out")
    svg.animate("fp", 6, [(0, "transform:scaleX(.18)"), (5.4, "transform:scaleX(1)"), (6, "transform:scaleX(1)")], "ease-in-out")
    svg.body.append(
        '<g class="fa"><rect x="718" y="196" width="244" height="72" rx="18" fill="#141b2e" fill-opacity=".94" stroke="#fff" stroke-opacity=".14"/>'
        '<circle cx="742" cy="219" r="6" fill="#22c55e"/><text x="756" y="225" font-size="15" font-weight="700" fill="#4ade80">Applied now</text>'
        '<text class="mono" x="736" y="252" font-size="15.5" fill="#dfe6f3">40.712982, -74.007205</text></g>'
        '<g class="fc"><rect x="706" y="300" width="252" height="80" rx="18" fill="#141b2e" fill-opacity=".94" stroke="#fff" stroke-opacity=".14"/>'
        '<text x="726" y="328" font-size="14" font-weight="700" fill="#93c5fd" letter-spacing="1.5">ROUTE PLAYING</text>'
        '<text x="726" y="352" font-size="17" font-weight="700" fill="#f5f7fb">3.2 km · 12 min left</text>'
        '<rect x="726" y="363" width="212" height="5" rx="2.5" fill="#fff" fill-opacity=".1"/><rect class="fp fl" x="726" y="363" width="212" height="5" rx="2.5" fill="#4f8bff"/></g>'
    )
    (HERE / "banner.svg").write_text(svg.render(), encoding="utf-8")


def flow():
    svg = Svg(960, 330, "How LSpoof answers a location request",
              "Your app asks Core Location or MapKit where you are. LSpoof's hooks inside the app answer with the spot you chose. When LSpoof is off, iOS answers with your real location.")
    card_background(svg, "#4f8bff", "f")
    nodes = [
        (40, "Your app", ["Asks where you are,", "like any app does"], "#4f8bff"),
        (355, "LSpoof hooks", ["Inside the app, on", "Core Location and MapKit"], "#a78bfa"),
        (670, "Your chosen spot", ["Held, moving on a route,", "or paused"], "#34d399"),
    ]
    period = 6.0
    for i, (x, title, lines, color) in enumerate(nodes):
        hit = period * (0.0, 0.17, 0.34)[i] + 0.15
        cls = f"nd{i}"
        svg.animate(cls, period, [(0, "stroke-opacity:.12"), (hit, "stroke-opacity:.12"), (hit + 0.2, "stroke-opacity:.9"), (hit + 0.9, "stroke-opacity:.12"), (period, "stroke-opacity:.12")])
        svg.body.append(
            f'<rect class="{cls}" x="{x}" y="58" width="250" height="132" rx="22" fill="#fff" fill-opacity=".045" stroke="{color}" stroke-opacity=".12" stroke-width="2"/>'
            f'<circle cx="{x + 34}" cy="96" r="14" fill="{color}" fill-opacity=".18"/><circle cx="{x + 34}" cy="96" r="6" fill="{color}"/>'
            f'<text x="{x + 58}" y="103" font-size="21" font-weight="750" fill="#f5f7fb">{esc(title)}</text>'
            + "".join(f'<text x="{x + 24}" y="{140 + 24 * j}" font-size="16" fill="#9aa5ba">{esc(line)}</text>' for j, line in enumerate(lines))
        )
    for x1, x2 in [(290, 355), (605, 670)]:
        svg.body.append(f'<path d="M{x1 + 6} 124H{x2 - 10}" stroke="#fff" stroke-opacity=".25" stroke-width="2" stroke-dasharray="4 6"/><path d="M{x2 - 12} 118l8 6-8 6" fill="none" stroke="#fff" stroke-opacity=".4" stroke-width="2"/>')
    # Request dot: app -> hooks -> spot.
    svg.body.append(
        '<g class="rq"><circle r="7" fill="#fff"/><circle r="13" fill="#fff" fill-opacity=".15"/>'
        f'<animateMotion dur="{period}s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;.02;.34;1" calcMode="linear" path="M290 124H355M605 124H670"/></g>'
    )
    svg.animate("rq", period, [(0, "opacity:0"), (period * 0.03, "opacity:1"), (period * 0.33, "opacity:1"), (period * 0.36, "opacity:0"), (period, "opacity:0")])
    back = "M795 190C795 252 700 262 480 262S165 252 165 190"
    svg.body.append(f'<path d="{back}" stroke="#34d399" stroke-opacity=".3" stroke-width="2" fill="none" stroke-dasharray="4 6"/>'
                    '<path d="M159 200l6-10 6 10" fill="none" stroke="#34d399" stroke-opacity=".6" stroke-width="2"/>')
    svg.body.append(
        '<g class="ans"><rect x="-86" y="-17" width="172" height="34" rx="17" fill="#0f2a22" stroke="#34d399" stroke-opacity=".8"/>'
        '<text class="mono" x="0" y="5.5" font-size="14" fill="#a7f3d0" text-anchor="middle">40.7130, -74.0072</text>'
        f'<animateMotion dur="{period}s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;.4;.82;1" calcMode="spline" keySplines="0 0 1 1;.4 0 .2 1;0 0 1 1" path="{back}"/></g>'
    )
    svg.animate("ans", period, [(0, "opacity:0"), (period * 0.4, "opacity:0"), (period * 0.44, "opacity:1"), (period * 0.84, "opacity:1"), (period * 0.9, "opacity:0"), (period, "opacity:0")])
    svg.css.append(".rq,.ans{opacity:0}")
    svg.body.append('<text x="480" y="306" font-size="15" fill="#6b7489" text-anchor="middle">Turned off, nothing is changed: iOS answers with your real location.</text>')
    (HERE / "how-it-works.svg").write_text(svg.render(), encoding="utf-8")


def main():
    banner()
    flow()
    guide("guide-location.svg", 1, "Guide 1 · Location", "Hold a location", "Anywhere on Earth, in three taps.", "#4f8bff", [
        {"screen": "search", "tap": (0.16, 0.251), "text": ["Search for a place,", "or tap a category"], "footer": "Or tap the map to drop a pin, and drag it to fine-tune."},
        {"screen": "search-coffee", "tap": (0.41, 0.372), "text": ["Pick a result"]},
        {"screen": "location", "tap": (0.43, 0.878), "text": ["Apply it. The app now", "sees you there"]},
    ])
    guide("guide-route.svg", 2, "Guide 2 · Route", "Play a route", "Walk, bike or drive, with up to 10 stops.", "#34d399", [
        {"screen": "route", "tap": (0.37, 0.57), "text": ["Set From and To,", "and add stops if you like"], "footer": "Each leg can have its own path and speed."},
        {"screen": "route-path", "tap": (0.71, 0.648), "text": ["Choose a walking or", "driving path"]},
        {"screen": "route-speed", "tap": (0.5, 0.763), "text": ["Pick a speed and motion,", "then start the route"]},
    ])
    guide("guide-coordinates.svg", 3, "Guide 3 · Coordinates", "Go to exact coordinates", "Decimal, degrees-minutes-seconds or a map link.", "#22d3ee", [
        {"screen": "search", "tap": (0.85, 0.105), "text": ["Tap Coordinates"], "footer": "Works offline, with Undo while you fine-tune."},
        {"screen": "coordinates", "tap": (0.83, 0.493), "text": ["Paste coordinates or", "a map link, or type them"]},
        {"screen": "coordinates", "tap": (0.5, 0.92), "text": ["Drag the map to fine-tune,", "then use the spot"]},
    ])
    guide("guide-saved.svg", 4, "Guide 4 · Saved", "Save places and routes", "Everything you use, one swipe away.", "#f59e0b", [
        {"screen": "saved", "tap": (0.794, 0.197), "text": ["Open Saved"], "footer": "Swipe right to apply, swipe left to rename or delete."},
        {"screen": "saved", "tap": (0.858, 0.635), "text": ["Tap ··· or touch and", "hold any row"]},
        {"screen": "saved-menu", "tap": (0.62, 0.4), "text": ["Apply, save, copy", "or share it"]},
    ])
    guide("guide-schedule.svg", 5, "Guide 5 · Schedule", "Schedule it", "Start later, stop later, repeat every day.", "#a78bfa", [
        {"screen": "location", "tap": (0.892, 0.878), "text": ["Tap the clock next to", "Apply or Start route"], "footer": "Runs while the app is open, or in the background."},
        {"screen": "schedule", "tap": (0.281, 0.52), "text": ["Pick a start time or", "a quick choice"]},
        {"screen": "schedule", "tap": (0.5, 0.929), "text": ["Turn off later or repeat", "daily, then Schedule"]},
    ])
    guide("guide-settings.svg", 6, "Guide 6 · Settings", "Make it yours", "Altitude, course, natural wander and backups.", "#f472b6", [
        {"screen": "location", "tap": (0.771, 0.128), "text": ["Tap the gear"], "footer": "Edits apply when you tap Save."},
        {"screen": "settings", "tap": (0.864, 0.458), "text": ["Set altitude, course", "and natural wander"]},
        {"screen": "settings-backup", "tap": (0.33, 0.717), "text": ["Back up to a file", "or the clipboard"]},
    ])
    for path in sorted(HERE.glob("*.svg")):
        print(f"{path.name}: {path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
