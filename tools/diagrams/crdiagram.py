"""Change Radar diagram primitives: one visual language for every figure in the documents.

Each figure is an SVG built from these primitives, then rendered to PNG (render.ps1, Microsoft Edge headless, the same
Segoe UI the Word documents use). Coordinates are in pixels on a canvas usually 1600 wide; Word scales the figure to the
text width. Keep text at 15 px or more so it stays legible at that scale.
"""
from html import escape

FONT = "Segoe UI, Arial, sans-serif"

# Design tokens. Neutral Change Radar identity (Simon, 2026-11-24): navy and teal, with one tint per TOGAF domain.
C = {
    "navy": "#1F3A5F", "teal": "#1C7C7D", "ink": "#22303C", "muted": "#5B6773", "line": "#8A96A3", "rule": "#D5DBE1",
    "paper": "#FFFFFF", "mist": "#F4F6F8",
    "business": "#FBEBCF", "business_e": "#C9922E",
    "data": "#DCEAF7", "data_e": "#3C78B4",
    "application": "#DDF1E7", "application_e": "#2F8A5E",
    "technology": "#E9E4F5", "technology_e": "#6A58A8",
    "external": "#F1F3F5", "external_e": "#8A96A3",
    "ai": "#EFE3F7", "ai_e": "#8A4FB0",
    "rule_k": "#DDF1E7", "rule_ke": "#2F8A5E",
    "human": "#FDE9C8", "human_e": "#C9822E",
    "alert": "#FBE3E1", "alert_e": "#B3261E",
}


class Figure:
    def __init__(self, width, height, title=None):
        self.w, self.h, self.items, self.defs = width, height, [], set()
        self.title = title

    # ----- low level -------------------------------------------------------------------------------------------------
    def add(self, s):
        self.items.append(s)

    def rect(self, x, y, w, h, fill="#fff", stroke=None, rx=10, sw=1.5, dash=None, opacity=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        o = f' fill-opacity="{opacity}"' if opacity is not None else ""
        st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{o}{st}{d}/>')

    def text(self, x, y, s, size=15, weight=400, color=None, anchor="start", italic=False):
        color = color or C["ink"]
        size = max(size, 14)  # print legibility: figures are placed on landscape pages, about 0.46 pt per pixel
        it = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" fill="{color}" '
                 f'text-anchor="{anchor}"{it}>{escape(s)}</text>')

    def lines(self, x, y, lines, size=15, weight=400, color=None, anchor="start", gap=1.3):
        for i, s in enumerate(lines):
            if s:
                self.text(x, y + i * size * gap, s, size, weight, color, anchor)

    # ----- shapes ----------------------------------------------------------------------------------------------------
    def box(self, x, y, w, h, title, body=(), fill="#fff", edge=None, size=16, body_size=14, align="center", rx=10,
            title_color=None, dash=None, sw=1.6):
        self.rect(x, y, w, h, fill, edge or C["line"], rx, sw, dash)
        n = len(body)
        block = size * 1.25 + n * body_size * 1.32
        top = y + (h - block) / 2 + size * 0.95
        if align == "center":
            cx = x + w / 2
            self.text(cx, top, title, size, 600, title_color, "middle")
            self.lines(cx, top + size * 0.35 + body_size * 1.15, body, body_size, 400, C["muted"], "middle", 1.32)
        else:
            self.text(x + 16, top, title, size, 600, title_color)
            self.lines(x + 16, top + size * 0.35 + body_size * 1.15, body, body_size, 400, C["muted"], "start", 1.32)

    def group(self, x, y, w, h, label, fill, edge, sub=None, dash=None, label_size=17):
        self.rect(x, y, w, h, fill, edge, 14, 1.8, dash)
        self.text(x + 18, y + 30, label, label_size, 700, edge)
        if sub:
            self.text(x + 18, y + 52, sub, 13.5, 400, C["muted"])

    def chip(self, x, y, label, fill, edge, size=12.5):
        w = len(label) * size * 0.58 + 18
        self.rect(x, y, w, size + 10, fill, edge, (size + 10) / 2, 1.2)
        self.text(x + w / 2, y + size + 1.5, label, size, 600, edge, "middle")
        return w

    def lane(self, y, h, label, fill, x=0, w=None, label_w=200):
        w = w or self.w
        self.rect(x, y, w, h, fill, C["rule"], 0, 1)
        self.rect(x, y, label_w, h, "#ffffff", C["rule"], 0, 1, opacity=0.55)
        words = label.split("\n")
        self.lines(x + label_w / 2, y + h / 2 - (len(words) - 1) * 10 + 5, words, 15.5, 700, C["navy"], "middle", 1.3)

    def _marker(self, color):
        mid = "arrow" + color.replace("#", "")
        if mid not in self.defs:
            self.defs.add(mid)
            self.add_def(f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
                         f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')
        return mid

    def add_def(self, s):
        self.items.insert(0, ("DEF", s))

    def arrow(self, pts, color=None, dash=None, width=2, label=None, at=None, both=False, label_color=None,
              label_size=13.5, label_bg=True):
        color = color or C["line"]
        mid = self._marker(color)
        d = "M" + " L".join(f"{px},{py}" for px, py in pts)
        ds = f' stroke-dasharray="{dash}"' if dash else ""
        start = f' marker-start="url(#{mid})"' if both else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{ds} marker-end="url(#{mid})"'
                 f'{start} stroke-linejoin="round"/>')
        if label:
            if at is None:
                a, b = pts[len(pts) // 2 - 1], pts[len(pts) // 2]
                at = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - 8)
            ls = label.split("\n")
            if label_bg:
                wmax = max(len(s) for s in ls) * label_size * 0.53 + 12
                hh = len(ls) * label_size * 1.3 + 6
                self.rect(at[0] - wmax / 2, at[1] - label_size - 2, wmax, hh, "#ffffff", None, 4, opacity=0.92)
            self.lines(at[0], at[1], ls, label_size, 500, label_color or C["muted"], "middle", 1.3)

    def link(self, pts, color=None, width=1.6, dash=None, label=None, at=None, label_size=12.5):
        """A plain relationship line (no arrowhead), for the data model."""
        color = color or C["line"]
        d = "M" + " L".join(f"{px},{py}" for px, py in pts)
        ds = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{ds} stroke-linejoin="round"/>')
        if label:
            if at is None:
                a, b = pts[0], pts[-1]
                at = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - 6)
            w = len(label) * label_size * 0.53 + 10
            self.rect(at[0] - w / 2, at[1] - label_size, w, label_size + 6, "#ffffff", None, 3, opacity=0.95)
            self.text(at[0], at[1], label, label_size, 500, C["muted"], "middle", italic=True)

    def chevron(self, x, y, w, h, fill, edge, first=False, notch=26):
        """A value-stream stage: a chevron pointing right."""
        pts = [(x, y), (x + w - notch, y), (x + w, y + h / 2), (x + w - notch, y + h), (x, y + h)]
        if not first:
            pts.append((x + notch, y + h / 2))
        p = " ".join(f"{px},{py}" for px, py in pts)
        self.add(f'<polygon points="{p}" fill="{fill}" stroke="{edge}" stroke-width="1.8" stroke-linejoin="round"/>')

    def radar(self, cx, cy, r, color=None):
        """The Change Radar name mark: three arcs and a blip."""
        color = color or C["teal"]
        for k, a in ((1, 1.0), (0.66, 0.85), (0.33, 0.7)):
            rr = r * k
            self.add(f'<path d="M{cx - rr},{cy} A{rr},{rr} 0 0 1 {cx + rr},{cy}" fill="none" stroke="{color}" '
                     f'stroke-width="{max(2, r * 0.12)}" stroke-linecap="round" opacity="{a}"/>')
        self.add(f'<line x1="{cx}" y1="{cy}" x2="{cx + r * 0.62}" y2="{cy - r * 0.62}" stroke="{C["navy"]}" '
                 f'stroke-width="{max(2, r * 0.1)}" stroke-linecap="round"/>')
        self.add(f'<circle cx="{cx + r * 0.42}" cy="{cy - r * 0.78}" r="{max(3, r * 0.11)}" fill="{C["alert_e"]}"/>')

    def legend(self, x, y, entries, size=13.5):
        """entries: list of (label, fill, edge, dashed?)"""
        cx = x
        for label, fill, edge, *rest in entries:
            dash = "6 4" if rest and rest[0] else None
            self.rect(cx, y, 26, 18, fill, edge, 4, 1.5, dash)
            self.text(cx + 34, y + 14, label, size, 500, C["muted"])
            cx += 34 + len(label) * size * 0.55 + 26

    # ----- output -------------------------------------------------------------------------------------------------------
    def svg(self):
        defs = [i[1] for i in self.items if isinstance(i, tuple)]
        body = [i for i in self.items if not isinstance(i, tuple)]
        title = f"<title>{escape(self.title)}</title>" if self.title else ""
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img">{title}<defs>{"".join(defs)}</defs>'
                f'<rect width="100%" height="100%" fill="#ffffff"/>' + "".join(body) + "</svg>")
