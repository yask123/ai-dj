#!/usr/bin/env python3
"""The stage: renders what the AI's "hands" are doing, frame by frame, from the engine's telemetry.

  stage.py out/<name>      -> out/<name>.stage.mp4   (needs <name>.wav, .tele.json, .decisions.json)

Two platters (rotation = the actual platter position the engine played, so scratches wobble exactly as heard),
a mixer column (EQ / filter knobs, channel faders, FX pills), a crossfader, a fingertip wherever the AI is
touching something, a decision panel showing Jev's typed answers + probabilities + latency, and a tool-call console.
"""
import json
import math
import subprocess
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1920
BG = (11, 11, 12)
INK = (236, 236, 236)
DIM = (120, 120, 124)
FAINT = (52, 52, 56)
ACC = (255, 90, 54)
DIN = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
TRACK_COL = {"yeah": (255, 90, 54), "crazy_in_love": (255, 177, 59), "jump_around": (63, 182, 255),
             "get_low": (198, 255, 63), "hot_in_herre": (255, 122, 182), "not_like_us": (199, 125, 255),
             "espresso": (217, 160, 102), "levitating": (122, 224, 255)}
PLATTERS = {"A": (250, 900), "B": (830, 900)}
R = 185
MIX_X = {"A": 495, "B": 585}

_font_cache = {}


def F(path, size):
    k = (path, size)
    if k not in _font_cache:
        _font_cache[k] = ImageFont.truetype(path, size)
    return _font_cache[k]


def short(title):
    return title.split(" – ")[1] if " – " in title else title


# ---------------------------------------------------------------- precomputed assets

def platter_base():
    s = 2 * R + 20
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = s // 2
    d.ellipse([c - R - 6, c - R - 6, c + R + 6, c + R + 6], fill=(24, 24, 26, 255))
    d.ellipse([c - R, c - R, c + R, c + R], fill=(14, 14, 15, 255))
    for r in range(84, R - 4, 3):
        a = 26 + (r * 37 % 11)
        d.ellipse([c - r, c - r, c + r, c + r], outline=(a, a, a + 2, 255), width=1)
    # static sheen (a reflection doesn't rotate with the record)
    sheen = Image.new("L", (s, s), 0)
    sd = ImageDraw.Draw(sheen)
    sd.pieslice([c - R, c - R, c + R, c + R], 200, 235, fill=38)
    sd.pieslice([c - R, c - R, c + R, c + R], 20, 55, fill=22)
    im.paste((255, 255, 255, 255), (0, 0), sheen.point(lambda v: v))
    return im


def label_img(track, title):
    s = 170
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    col = TRACK_COL.get(track, (200, 200, 200))
    d.ellipse([5, 5, s - 5, s - 5], fill=col + (255,))
    d.ellipse([s / 2 - 6, s / 2 - 6, s / 2 + 6, s / 2 + 6], fill=BG + (255,))
    name = short(title).upper()
    name = name if len(name) <= 16 else name[:15] + "…"
    f = F(DIN, 26 if len(name) < 12 else 20)
    tw = d.textlength(name, font=f)
    d.text((s / 2 - tw / 2, s / 2 - 44), name, font=f, fill=BG + (255,))
    d.rectangle([s / 2 - 3, s - 30, s / 2 + 3, s - 12], fill=BG + (255,))  # orientation tick
    return im


# ---------------------------------------------------------------- tool calls derived from decisions

def tool_calls(log, meta, bars, brain="jev"):
    calls = []  # (beat_abs, text)
    for l in log:
        b = l["bar"]
        B = b * 4
        D = (l.get("deck") or "A").lower()
        N = "b" if D == "a" else "a"
        nx = l.get("next")
        nt = short(meta[nx]["title"]) if nx and nx in meta else ""
        word = meta[nx]["word"] if nx and nx in meta else ""
        mv, st = l["move"], l.get("scratch") or "baby"
        final = b >= bars - 1
        if l.get("decided_at_bar") is not None and mv not in ("ride",) and l.get("ms"):
            calls.append(((b - 2) * 4 + 0.05, f"{brain}.decide(bar={b}) -> {mv}  {l['ms']:.0f}ms" + ("  LATE" if l.get("late") else "")))
        if mv == "scratch_intro":
            tr = meta[l["track"]]
            calls += [(0, f'deck_a.load("{short(tr["title"])}", cue="{tr["word"]}")'), (0.1, f"deck_a.scratch(style={st})"),
                      (3.5, "deck_a.release()"), (4, "fx.impact()")]
        elif mv in ("scratch_in", "chop_cut", "echo_out_cut", "spinback_cut", "brake_cut", "roll_build_cut", "drop_gap_cut") and not final:
            calls.append(((b - 2) * 4 + 0.3, f'deck_{N}.load("{nt}", cue=hook)'))
            if mv == "scratch_in":
                calls += [(B, f"mixer.eq(deck_{D}, low=kill, mid=-9dB)"), (B + 0.05, f"mixer.mute(deck_{D}, vocals)"),
                          (B + 0.15, f'deck_{N}.scratch("{word}", style={st})'), (B + 3.5, f"deck_{N}.release()"),
                          (B + 4, f"mixer.crossfade(to=deck_{N})")]
            elif mv == "chop_cut":
                calls += [(B, f"deck_{N}.play(from=hook-1bar)"), (B + 0.1, "mixer.crossfader_chops(every=1/2 beat)"),
                          (B + 4, f"mixer.crossfade(to=deck_{N})")]
            elif mv == "echo_out_cut":
                calls += [(B + 3, f"fx.echo(deck_{D}, 3/4 beat, send=100%)"), (B + 3.02, f"deck_{D}.loop(1 beat)"),
                          (B + 4, f"deck_{D}.stop()"), (B + 4.02, f"deck_{N}.play()")]
            elif mv == "spinback_cut":
                calls += [(B + 2, f"deck_{D}.spinback()"), (B + 4, f"deck_{N}.play()"), (B + 4.02, "fx.impact()")]
            elif mv == "brake_cut":
                calls += [(B + 2, f"deck_{D}.brake()"), (B + 4, f"deck_{N}.play()"), (B + 4.02, "fx.impact()")]
            elif mv == "roll_build_cut":
                calls += [(B, f"deck_{D}.roll(1)"), (B + 0.02, "fx.noise_riser(1 bar)"), (B + 0.04, f"mixer.filter(deck_{D}, hp=rising)"),
                          (B + 2, f"deck_{D}.roll(1/2)"), (B + 3, f"deck_{D}.roll(1/4)"), (B + 3.5, f"deck_{D}.roll(1/8)"),
                          (B + 4, f"deck_{N}.play()"), (B + 4.02, "fx.impact()")]
            elif mv == "drop_gap_cut":
                calls += [(B + 3, f"mixer.mute(deck_{D})"), (B + 4, f"deck_{N}.play()"), (B + 4.02, "fx.impact()")]
        elif final:
            calls += [(B + 2, {"echo_out_cut": f"fx.echo(deck_{D}, send=100%)", "brake_cut": f"deck_{D}.brake()",
                               "spinback_cut": f"deck_{D}.spinback()"}.get(mv, mv)), (B + 4, f"deck_{D}.stop()  # end")]
        elif mv == "scratch_fill":
            calls += [(B + 2, f"mixer.mute(deck_{D}, instrumental)"),
                      (B + 2.05, f'deck_{D}.scratch("{meta[l["track"]]["word"]}", style={st})'), (B + 4, f"mixer.unmute(deck_{D})")]
        elif mv == "roll_fill":
            calls += [(B + 3, f"deck_{D}.roll(1/4)"), (B + 3.5, f"deck_{D}.roll(1/8)")]
        elif mv == "echo_throw":
            calls += [(B + 3, f"fx.echo(deck_{D}, send=90%)")]
        elif mv == "filter_dip":
            calls += [(B, f"mixer.filter(deck_{D}, lp=sweep down)"), (B + 3.75, f"mixer.filter(deck_{D}, reset)")]
    return sorted(calls)


# ---------------------------------------------------------------- drawing

def fingertip(d, x, y, strength=1.0):
    a = int(210 * strength)
    d.ellipse([x - 34, y - 34, x + 34, y + 34], outline=ACC + (int(70 * strength),), width=2)
    d.ellipse([x - 19, y - 19, x + 19, y + 19], fill=ACC + (a,))


def knob(d, x, y, v, label, lo=-60, hi=12, bipolar=False, active=False):
    """v: dB (EQ) or -1..1 (filter). Arc from 225deg to -45deg."""
    r = 17
    d.ellipse([x - r, y - r, x + r, y + r], fill=(28, 28, 30), outline=FAINT, width=2)
    if bipolar:
        frac = (v + 1) / 2
    else:
        frac = (np.clip(v, lo, hi) - lo) / (hi - lo)
    ang = math.radians(225 - 270 * frac)
    d.line([x, y, x + (r - 3) * math.cos(ang), y - (r - 3) * math.sin(ang)], fill=INK if not active else ACC, width=3)
    # value arc
    zero = 225 - 270 * ((0 - lo) / (hi - lo) if not bipolar else 0.5)
    a0, a1 = sorted([zero, 225 - 270 * frac])
    if a1 - a0 > 2:
        d.arc([x - r - 6, y - r - 6, x + r + 6, y + r + 6], -a1, -a0, fill=ACC if active or abs(a1 - a0) > 20 else DIM, width=3)
    f = F(DIN, 17)
    tw = d.textlength(label, font=f)
    d.text((x - tw / 2, y + r + 5), label, font=f, fill=DIM)


class Stage:
    def __init__(self, base):
        self.base = Path(base)
        tele = json.loads(Path(f"{base}.tele.json").read_text())
        dec = json.loads(Path(f"{base}.decisions.json").read_text())
        mp = Path(f"{base}.meta.json")
        self.meta = json.loads(mp.read_text() if mp.exists() else (self.base.parent.parent / "crate.json").read_text())
        self.brain = dec.get("brain", "jev")
        self.model = dec.get("model", self.brain)
        pal = [(255, 90, 54), (63, 182, 255), (198, 255, 63), (255, 177, 59)]
        for k, t in enumerate(self.meta):
            TRACK_COL.setdefault(t, pal[k % len(pal)])
        self.fps, self.bpm = tele["fps"], dec["bpm"]
        self.frames = tele["frames"]
        self.log = dec["log"]
        self.bars = dec["bars"]
        self.beat_s = 60 / self.bpm
        self.calls = tool_calls(self.log, self.meta, self.bars, self.brain.replace("-", "_").replace(".", "_"))
        self.decisions = [l for l in self.log if l.get("ms")]
        self.segments = []
        cur, start = None, 0
        for i, fr in enumerate(self.frames):
            loud = max(fr["decks"].items(), key=lambda kv: kv[1]["gain"] + (0 if kv[1]["env"] > 0.05 else -99), default=(None, None))
            tr = loud[1]["track"] if loud[1] else cur
            if tr != cur:
                if cur:
                    self.segments.append((cur, start, i))
                cur, start = tr, i
        self.segments.append((cur, start, len(self.frames)))
        # control-change history for "the hand is on it"
        self.touch_hold = {}
        prev = {}
        for i, fr in enumerate(self.frames):
            for dn, dk in fr["decks"].items():
                for k in ("low", "mid", "high", "filter", "gain"):
                    key = (dn, k)
                    v = dk[k]
                    if key in prev and abs(v - prev[key]) > (0.004 if k == "filter" else 0.4):
                        self.touch_hold[(i, dn, k)] = 1
                    prev[key] = v
        self.touch_frames = {}
        for (i, dn, k) in self.touch_hold:
            for j in range(i, i + 7):
                self.touch_frames.setdefault((j, dn, k), 1.0 - (j - i) / 7)
        cp = Path(f"{base}.captions.json")
        self.captions = json.loads(cp.read_text()) if cp.exists() else []
        self.base_img = platter_base()
        self.labels = {t: label_img(t, self.meta[t]["title"]) for t in self.meta}

    def xfader(self, fr):
        g = {dn: (10 ** (dk["gain"] / 20) if dk["gain"] > -59 else 0) * (1 if dk["env"] > 0.02 or dk["touch"] == "" else 0.3)
             for dn, dk in fr["decks"].items()}
        a, b = g.get("A", 0), g.get("B", 0)
        return 0.0 if a + b == 0 else (b - a) / (a + b)

    def draw(self, i):
        fr = self.frames[i]
        t = i / self.fps
        beat = t / self.beat_s
        im = Image.new("RGB", (W, H), BG)
        ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        o = ImageDraw.Draw(ov)

        # ---------------- header
        d.text((60, 70), "AI DJ", font=F(DIN, 64), fill=ACC)
        d.text((222, 70), self.brain.upper(), font=F(DIN, 64), fill=INK)
        mid = "TYPESAFE/JEV-1.13" if self.brain == "jev" else str(self.model).upper()
        d.text((60, 146), f"LIVE  ·  EVERY MOVE DECIDED BY {mid}", font=F(DIN, 27), fill=DIM)
        bb = f"BAR {int(beat // 4):02d}.{int(beat % 4) + 1}"
        f = F(MONO, 30)
        d.text((W - 60 - d.textlength(bb, font=f), 82), bb, font=f, fill=INK)
        s2 = f"{self.bpm:g} BPM"
        d.text((W - 60 - d.textlength(s2, font=F(DIN, 27)), 146), s2, font=F(DIN, 27), fill=DIM)
        # beat pulse dots
        for k in range(4):
            on = int(beat % 4) == k
            x = W - 60 - 4 * 22 + k * 22 + 8
            d.ellipse([x - 5, 128 - 5, x + 5, 128 + 5], fill=ACC if on and beat % 1 < 0.3 else (INK if on else FAINT))

        # ---------------- brain panel
        self.draw_brain(d, o, t)

        # ---------------- decks
        for dn, (cx, cy) in PLATTERS.items():
            dk = fr["decks"].get(dn)
            im.paste(self.base_img, (cx - R - 10, cy - R - 10), self.base_img)
            if dk:
                lab = self.labels[dk["track"]].rotate(-dk["angle"], resample=Image.BICUBIC)
                im.paste(lab, (cx - 85, cy - 85), lab)
                ang = math.radians(dk["angle"] - 90)
                x2, y2 = cx + (R - 12) * math.cos(ang), cy + (R - 12) * math.sin(ang)
                d.line([cx + 88 * math.cos(ang), cy + 88 * math.sin(ang), x2, y2], fill=INK, width=3)
                title = short(self.meta[dk["track"]]["title"]).upper()
                col = TRACK_COL.get(dk["track"], INK)
                heard = dk["gain"] > -40 and (dk["env"] > 0.05)
                d.text((cx - d.textlength(title, font=F(DIN, 34)) / 2, cy - R - 64), title, font=F(DIN, 34),
                       fill=col if heard else DIM)
                touch = dk["touch"]
                rl = "LOOP 1 BEAT" if dk["roll"] >= 1 or dk["roll"] <= 0 else f"ROLL 1/{int(round(1 / dk['roll']))}"
                state = {"": "PLAY", "roll": rl,
                         "spinback": "SPINBACK", "brake": "BRAKE", "mute": "CUT"}.get(touch, touch.replace("scratch:", "SCRATCH · ").upper())
                d.text((cx - d.textlength(state, font=F(MONO, 22)) / 2, cy + R + 22), state, font=F(MONO, 22),
                       fill=ACC if touch else DIM)
                if touch.startswith("scratch") or touch in ("spinback", "brake"):
                    # the hand on the record: fingertip rides the platter edge + a motion trail
                    for back in range(6, 0, -1):
                        j = max(0, i - back)
                        pk = self.frames[j]["decks"].get(dn)
                        if pk:
                            aa = math.radians(pk["angle"] - 90)
                            px, py = cx + (R - 40) * math.cos(aa), cy + (R - 40) * math.sin(aa)
                            rr = 16 - back * 2
                            o.ellipse([px - rr, py - rr, px + rr, py + rr], fill=ACC + (int(90 - back * 13),))
                    fx, fy = cx + (R - 40) * math.cos(ang), cy + (R - 40) * math.sin(ang)
                    fingertip(o, fx, fy)
            else:
                d.text((cx - d.textlength("—", font=F(DIN, 34)) / 2, cy - R - 64), "—", font=F(DIN, 34), fill=FAINT)
            if "impact" in fr["fx"] and dk:
                pass
            # impact ring (a few frames after)
            for back in range(0, 10):
                j = i - back
                if j >= 0 and "impact" in self.frames[j]["fx"] and dk:
                    rr = R + 8 + back * 7
                    o.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=INK + (int(160 - back * 16),), width=3)

        # ---------------- mixer column
        for dn, x in MIX_X.items():
            dk = fr["decks"].get(dn, {"high": 0, "mid": 0, "low": 0, "filter": 0, "gain": -60, "echo": 0, "reverb": 0})
            ys = [700, 760, 820, 880]
            for (k, lab, y) in zip(("high", "mid", "low", "filter"), ("HI", "MID", "LOW", "FILTER"), ys):
                act = self.touch_frames.get((i, dn, k), 0)
                knob(d, x, y, dk[k], lab, bipolar=(k == "filter"), active=act > 0)
                if act:
                    fingertip(o, x + 20, y - 10, act * 0.85)
            # fx pills
            for j, (k, lab) in enumerate((("echo", "ECHO"), ("reverb", "VERB"))):
                on = dk[k] > 0.05
                y = 935 + j * 34
                d.rounded_rectangle([x - 34, y, x + 34, y + 26], radius=13, fill=ACC if on else (28, 28, 30))
                ff = F(DIN, 19)
                d.text((x - d.textlength(lab, font=ff) / 2, y + 3), lab, font=ff, fill=BG if on else DIM)
            # channel fader
            y0, y1 = 1015, 1135
            d.rectangle([x - 3, y0, x + 3, y1], fill=(34, 34, 36))
            g = dk["gain"]
            frac = 0 if g <= -59 else np.clip((g + 30) / 36, 0, 1)
            cy = y1 - frac * (y1 - y0)
            d.rounded_rectangle([x - 20, cy - 9, x + 20, cy + 9], radius=4, fill=INK if frac > 0 else DIM)
            act = self.touch_frames.get((i, dn, "gain"), 0)
            d.text((x - d.textlength(dn, font=F(DIN, 24)) / 2, 1145), dn, font=F(DIN, 24), fill=DIM)
            # level meter beside
            lv = fr.get("rms", 0) * (frac > 0)
        # crossfader
        xf = self.xfader(fr)
        x0, x1, y = 390, 690, 1230
        d.rectangle([x0, y - 3, x1, y + 3], fill=(34, 34, 36))
        cx = (x0 + x1) / 2 + xf * (x1 - x0) / 2
        d.rounded_rectangle([cx - 13, y - 22, cx + 13, y + 22], radius=4, fill=INK)
        d.text((x0 - 30, y - 14), "A", font=F(DIN, 26), fill=DIM)
        d.text((x1 + 16, y - 14), "B", font=F(DIN, 26), fill=DIM)
        pxf = self.xfader(self.frames[max(0, i - 1)])
        if abs(xf - pxf) > 0.2 or any(abs(self.xfader(self.frames[max(0, i - k)]) - self.xfader(self.frames[max(0, i - k - 1)])) > 0.2 for k in range(1, 5)):
            fingertip(o, cx, y - 34)

        # ---------------- console
        self.draw_console(d, beat)

        # ---------------- timeline (or a caption over it)
        self.draw_timeline(d, i)
        for c in self.captions:
            if c["t0"] <= t < c["t1"]:
                a = min(1, (t - c["t0"]) / 0.15, (c["t1"] - t) / 0.2)
                o.rectangle([0, 1686, W, H], fill=BG + (int(255 * a),))
                o.rectangle([60, 1700, 66, 1700 + (118 if c.get("sub") else 70)], fill=ACC + (int(255 * a),))
                ff = F(DIN, 64)
                txt = c["text"].upper()
                while o.textlength(txt, font=ff) > W - 150 and ff.size > 36:
                    ff = F(DIN, ff.size - 4)
                o.text((88, 1702), txt, font=ff, fill=INK + (int(255 * a),))
                if c.get("sub"):
                    o.text((90, 1784), c["sub"], font=F(MONO, 26), fill=DIM + (int(255 * a),))
        im.paste(ov, (0, 0), ov)
        return im.tobytes()

    def draw_brain(self, d, o, t):
        y0 = 215
        d.line([60, y0, W - 60, y0], fill=FAINT, width=1)
        cur = None
        for l in self.decisions:
            ts = max(0, l["decided_at_bar"]) * 4 * self.beat_s
            if ts <= t:
                cur = (l, ts)
        if not cur:
            d.text((60, y0 + 22), f"{self.brain.upper()}  ·  LISTENING", font=F(DIN, 40), fill=DIM)
            return
        l, ts = cur
        el = t - ts
        think = max(l["ms"] / 1000, 0.35)
        d.text((60, y0 + 22), f"{self.brain.upper()}  ·  NEXT MOVE FOR BAR {l['bar']}", font=F(DIN, 40), fill=INK)
        badge = f"{l['ms']:.0f} MS"
        bf = F(MONO, 24)
        bw = d.textlength(badge, font=bf)
        d.rounded_rectangle([W - 60 - bw - 28, y0 + 24, W - 60, y0 + 62], radius=19, fill=ACC if el < think + 0.4 else (40, 40, 42))
        d.text((W - 60 - bw - 14, y0 + 30), badge, font=bf, fill=BG if el < think + 0.4 else INK)
        probs = l.get("probs") or {}
        if probs:
            rows = sorted(probs.items(), key=lambda kv: -kv[1])[:6]
        else:
            opts = l.get("options") or [l["move"]]
            rows = [(o, None) for o in ([l["move"]] + [o for o in opts if o != l["move"]])][:6]
        if l.get("late") or l.get("invalid"):
            msg = f"TOO SLOW · WANTED {str(l.get('wanted')).upper()} · FELL BACK TO {l['move'].upper()}" if l.get("late") else \
                f"INVALID ANSWER {str(l.get('wanted'))[:24].upper()} · FELL BACK TO {l['move'].upper()}"
            if el >= think:
                d.text((60, y0 + 70), msg, font=F(DIN, 24), fill=ACC)
        grow = np.clip((el - think) / 0.25, 0, 1) if el >= think else 0
        fy = y0 + 90
        for k, (name, p) in enumerate(rows):
            y = fy + k * 44
            chosen = name == l["move"]
            col = ACC if chosen and grow > 0 else (INK if grow > 0 else DIM)
            label = name.replace("_cut", "").replace("_", " ")
            d.text((60, y), ("› " if chosen and grow > 0 else "  ") + label, font=F(MONO, 25), fill=col)
            bx0, bx1 = 400, 860
            d.rectangle([bx0, y + 10, bx1, y + 22], fill=(26, 26, 28))
            if el < think:  # thinking shimmer
                ph = (el * 3 + k * 0.17) % 1
                sx = bx0 + ph * (bx1 - bx0)
                if min(bx1, sx + 40) > max(bx0, sx - 40):
                    d.rectangle([max(bx0, sx - 40), y + 10, min(bx1, sx + 40), y + 22], fill=(60, 60, 64))
            elif p is not None:
                d.rectangle([bx0, y + 10, bx0 + (bx1 - bx0) * p * grow, y + 22], fill=ACC if chosen else (150, 150, 155))
                d.text((bx1 + 18, y), f"{p * 100:3.0f}%", font=F(MONO, 25), fill=col)
            elif chosen:
                d.rectangle([bx0, y + 10, bx0 + (bx1 - bx0) * grow, y + 22], fill=ACC)
                d.text((bx1 + 18, y), "pick", font=F(MONO, 25), fill=col)
        # secondary answers
        y = fy + 6 * 44 + 8
        if grow > 0:
            parts = []
            if l.get("next") and l["move"] not in ("ride", "filter_dip", "echo_throw", "roll_fill", "scratch_fill") and l["bar"] < self.bars - 1:
                np_ = (l.get("next_probs") or {}).get(l["next"])
                parts.append(f"NEXT › {short(self.meta[l['next']]['title']).upper()}" + (f" {np_ * 100:.0f}%" if np_ else ""))
            if "scratch" in l["move"]:
                sp = (l.get("scratch_probs") or {}).get(l.get("scratch"))
                parts.append(f"STYLE › {l['scratch'].upper()}" + (f" {sp * 100:.0f}%" if sp else ""))
            parts.append(f"HYPE › {['SMOOTH', 'STEADY', 'HYPE', 'PEAK'][int(np.clip(l.get('hype') or 2, 0, 3))]}")
            d.text((60, y), "   ·   ".join(parts), font=F(DIN, 28), fill=DIM)

    def draw_console(self, d, beat):
        y0 = 1300
        d.line([60, y0 - 16, W - 60, y0 - 16], fill=FAINT, width=1)
        d.text((60, y0), "TOOL CALLS", font=F(DIN, 24), fill=DIM)
        shown = [(b, s) for b, s in self.calls if b <= beat][-9:]
        f = F(MONO, 23)
        for k, (b, s) in enumerate(shown):
            y = y0 + 38 + k * 34
            age = beat - b
            n = int(len(s) * np.clip(age / 0.35, 0, 1)) if k == len(shown) - 1 or age < 0.35 else len(s)
            newest = age < 1.0
            ts = f"{int(b // 4):02d}.{int(b % 4) + 1}"
            d.text((60, y), ts, font=f, fill=FAINT if not newest else DIM)
            col = INK if newest else (110, 110, 114)
            if ".decide(" in s:
                col = ACC if newest else (150, 80, 60)
            d.text((140, y), "› " + s[:n], font=f, fill=col)

    def draw_timeline(self, d, i):
        y = 1760
        x0, x1 = 60, W - 60
        n = len(self.frames)
        d.rectangle([x0, y, x1, y + 26], fill=(22, 22, 24))
        for tr, a, b in self.segments:
            if a > i:
                continue
            b = min(b, i)
            xa, xb = x0 + (x1 - x0) * a / n, x0 + (x1 - x0) * b / n
            if xb - xa < 4:
                continue
            d.rectangle([xa + 1, y, xb - 1, y + 26], fill=TRACK_COL.get(tr, DIM))
            if xb - xa > 60:
                nm = short(self.meta[tr]["title"]).upper()
                ff = F(DIN, 18)
                if d.textlength(nm, font=ff) < xb - xa - 10:
                    d.text((xa + 6, y + 4), nm, font=ff, fill=BG)
        px = x0 + (x1 - x0) * i / n
        d.rectangle([px - 1, y - 10, px + 1, y + 36], fill=INK)
        # master level
        lv = np.clip((20 * np.log10(self.frames[i].get("rms", 1e-4) + 1e-6) + 30) / 26, 0, 1)
        d.rectangle([x0, y + 56, x1, y + 62], fill=(26, 26, 28))
        d.rectangle([x0, y + 56, x0 + (x1 - x0) * lv, y + 62], fill=INK)
        d.text((x0, y + 76), "MASTER", font=F(DIN, 20), fill=FAINT)


_S = None


def _init(base):
    global _S
    _S = Stage(base)


def _draw(i):
    return _S.draw(i)


def main():
    base = sys.argv[1].replace(".wav", "")
    S = Stage(base)
    n = len(S.frames)
    out = f"{base}.stage.mp4"
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                           "-r", str(S.fps), "-i", "-", "-i", f"{base}.wav", "-map", "0:v", "-map", "1:a",
                           "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", out], stdin=subprocess.PIPE)
    with Pool(12, initializer=_init, initargs=(base,)) as pool:
        for k, buf in enumerate(pool.imap(_draw, range(n), chunksize=8)):
            ff.stdin.write(buf)
            if k % 300 == 0:
                print(f"frame {k}/{n}", file=sys.stderr)
    ff.stdin.close()
    ff.wait()
    print(out)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--frame":
        S = Stage(sys.argv[1])
        for i in map(int, sys.argv[3:]):
            Image.frombytes("RGB", (W, H), S.draw(i)).save(f"{sys.argv[1]}.f{i}.png")
    else:
        main()
