#!/usr/bin/env python3
"""Live AI DJ: Jev (TypeSafe's fast decision model) performs a quick-mix bar by bar.

Split brain:
  * prep (slow, smart): crate.json — hot cues, hook length, scratch stab, vibe per track (prepared by Claude)
  * performance (fast): every bar the conductor asks Jev ONE typed call (move / next song / scratch style / hype)
    for the bar two bars ahead; the engine renders bar-by-bar with stateful DSP. Audio runs ~2 bars behind the
    decisions (the "delay"), so a 70–500 ms decision always lands on time.

  live.py [--brain jev|mock] [--bars 28] [--bpm 104] [--live] [--seed 3] [--name jev_set1]
  --live   plays through the speakers in real time; type a crowd request + Enter while it plays ("more scratching!")
"""
import argparse
import json
import os
import queue
import random
import sys
import threading
import time
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

import dj

ROOT = Path(__file__).parent
SR = dj.SR
CACHE = ROOT / "cache"
OUT = ROOT / "out"


# ================================================================ crate: pre-stretched decks

class Track:
    """A deck-ready track: only the cue regions are time-stretched to the master tempo (fast), mix + vocals in parallel."""

    def __init__(self, name, meta, bpm):
        from concurrent.futures import ThreadPoolExecutor
        self.name, self.meta = name, meta
        t = dj.lib(name)
        self.info = t
        spbar = 4 * 60 / bpm * SR
        self.spbar = spbar
        CACHE.mkdir(exist_ok=True)
        cues = meta.get("cues") or [meta["hook"]]
        f = meta.get("time_factor", 1)
        self.bar0 = max(0, min(cues) - 2)
        bar1 = max(cues) + meta.get("hook_len", 8) + 6
        bpm_eff = meta.get("bpm_eff", t["bpm"])
        src_bar_sec = 4 * 60 / bpm_eff

        pitch = meta.get("pitch", 0)  # key shift in semitones (harmonic mixing)

        def load(stem):
            cp = CACHE / f"live_{name}_{bpm}_{stem}_r{self.bar0}-{bar1}{'' if f == 1 else f'_x{f:g}'}{f'_p{pitch:+g}' if pitch else ''}.npy"
            if not cp.exists():
                import pyrubberband as prb
                src = dj._load(dj.TRACKS / f"{name}.wav" if stem == "mix" else dj.STEMS / name / f"{stem}.wav")
                a = int(round((t["first_downbeat"] + self.bar0 * src_bar_sec) * SR))
                b = int(round((t["first_downbeat"] + bar1 * src_bar_sec) * SR))
                y = src[a:b]
                ratio = bpm / bpm_eff
                if abs(ratio - 1) > 1e-4 or pitch:
                    y = prb.time_stretch(y, SR, ratio, rbargs={"--fine": "", **({"--pitch": str(pitch)} if pitch else {})})
                np.save(cp, y.astype(np.float32))
            return np.load(cp)
        with ThreadPoolExecutor(2) as ex:
            mix, vox = ex.map(load, ("mix", "vocals"))
        n = min(len(mix), len(vox))
        self.mix, self.vox = mix[:n], vox[:n]
        self.inst = self.mix - self.vox
        # loudness trim so every hook hits equally hard
        h = int((meta["hook"] - self.bar0) * spbar)
        seg = self.mix[h:h + int(4 * spbar)]
        self.trim = float(10 ** (-14 / 20) / (np.sqrt(np.mean(seg ** 2)) + 1e-6))

    def bar_sample(self, bar):
        return bar * self.spbar


# ================================================================ read maps (how the "platter" moves)

def _ease(u):
    return 0.5 - 0.5 * np.cos(np.pi * np.clip(u, 0, 1))


SCRATCHES = {
    # strokes per 1-beat cell: (t0, t1, p0, p1, fader_on) in beats / fraction of the stab; repeated across the span
    "baby": [(0, .5, 0, 1, 1), (.5, 1, 1, 0, 1)],
    "chirp": [(0, .25, 0, 1, 1), (.25, .5, 1, 0, 0), (.5, .75, 0, 1, 1), (.75, 1, 1, 0, 0)],
    "transformer": [(0, 1, 0, 1, "gate"), (1, 2, 1, 0, "gate")],
    "scribble": [(0, 1, 0, 1, "scribble"), (1, 1.25, 1, 0, 1), (1.25, 2, 0, 0, 0)],
    "tear": [(0, .125, 0, .5, 1), (.125, .25, .5, .5, 1), (.25, .375, .5, 1, 1), (.375, .5, 1, .5, 1), (.5, 1, .5, 0, 1)],
    "flare": [(0, .5, 0, 1, "flare"), (.5, 1, 1, 0, "flare")],
}


def scratch_map(pattern, n, spb, stab, L):
    """Platter position (samples into the track) + fader envelope for a scratch pattern over n samples."""
    cells = SCRATCHES[pattern]
    cell_len = max(c[1] for c in cells)
    t = np.arange(n) / spb  # beats
    tc = np.mod(t, cell_len)
    pos = np.zeros(n)
    fad = np.zeros(n)
    for t0, t1, p0, p1, f in cells:
        m = (tc >= t0) & (tc < t1)
        u = (tc[m] - t0) / (t1 - t0)
        pp = p0 + (p1 - p0) * _ease(u)
        if f == "scribble":
            pp = pp + 0.045 * np.sin(2 * np.pi * 7 * u * (t1 - t0) * 4)
        pos[m] = pp
        if f == "scribble":
            fad[m] = 1.0
        elif f == "gate":
            fad[m] = (np.mod(tc[m], 0.125) < 0.07).astype(float)
        elif f == "flare":
            fad[m] = ~((u > 0.45) & (u < 0.58))
        else:
            fad[m] = float(f)
    pos = stab + pos * L
    # vinyl only sounds while moving: gain follows platter speed; soften fader clicks (~2 ms)
    vel = np.abs(np.gradient(pos))  # samples per sample (1.0 = normal speed)
    g = np.clip(vel / 0.25, 0, 1) * fad
    k = int(0.002 * SR)
    g = np.convolve(g, np.ones(k) / k, mode="same")
    return pos, g


def spin_map(n, start, back=True, beats=None, spb=None):
    if back:  # rewind: accelerating backwards
        sp = 1 + 7 * np.linspace(0, 1, n) ** 2
        pos = start - np.cumsum(sp)
        g = np.linspace(1, 0.0, n) ** 0.7
    else:  # brake: platter slows to a stop
        sp = np.linspace(1, 0, n) ** 1.4
        pos = start + np.cumsum(sp)
        g = np.linspace(1, 0.3, n)
    return pos, g


# ================================================================ stateful DSP per deck / master

class DeckDSP:
    def __init__(self):
        from pedalboard import LadderFilter, Reverb
        self.lo = dj.signal.butter(4, 220, "low", fs=SR, output="sos")
        self.hi = dj.signal.butter(4, 2800, "high", fs=SR, output="sos")
        self.zlo = np.zeros((self.lo.shape[0], 2, 2))
        self.zhi = np.zeros((self.hi.shape[0], 2, 2))
        self.lp = LadderFilter(mode=LadderFilter.Mode.LPF24, cutoff_hz=20000, resonance=0.3)
        self.hp = LadderFilter(mode=LadderFilter.Mode.HPF24, cutoff_hz=20, resonance=0.3)
        self.rev = Reverb(room_size=0.85, damping=0.4, wet_level=1.0, dry_level=0.0, width=1.0)
        self.state = {"gain": 0.0, "vox": 0.0, "inst": 0.0, "low": 0.0, "mid": 0.0, "high": 0.0,
                      "filter": 0.0, "echo": 0.0, "reverb": 0.0}

    def eq(self, x, low, mid, high):
        lo, self.zlo = signal.sosfilt(self.lo, x, axis=0, zi=self.zlo)
        hi, self.zhi = signal.sosfilt(self.hi, x, axis=0, zi=self.zhi)
        return lo * low[:, None] + (x - lo - hi) * mid[:, None] + hi * high[:, None]

    def filt(self, x, knob):
        out = np.empty_like(x)
        for i in range(0, len(x), 256):
            k = float(knob[i])
            self.lp.cutoff_hz = float(20000 * (40 / 20000) ** max(0.0, -k)) if k < -0.01 else 20000
            self.hp.cutoff_hz = float(20 * (8000 / 20) ** max(0.0, k)) if k > 0.01 else 20
            c = x[i:i + 256]
            y = self.hp(self.lp(np.ascontiguousarray(c.T), SR, reset=False), SR, reset=False).T
            out[i:i + 256] = y if abs(k) > 0.01 else c
        return out


def keyed(keys, cur, n, spb):
    """[(beat, value), ...] within this bar -> per-sample curve, starting from the deck's current value."""
    if not keys:
        return np.full(n, cur, np.float32), cur
    keys = sorted(keys)
    xs = [0.0] + [k[0] * spb for k in keys]
    ys = [cur] + [k[1] for k in keys]
    for i in range(1, len(xs)):
        if xs[i] <= xs[i - 1]:
            xs[i] = xs[i - 1] + 1e-3
    return np.interp(np.arange(n), xs, ys).astype(np.float32), float(ys[-1])


def impact(spb):
    """Sub-drop boom + noise crack for the downbeat of a drop."""
    n = int(3 * spb)
    t = np.arange(n) / SR
    f = 30 + 35 * np.exp(-t * 5)
    sub = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.2)
    rng = np.random.default_rng(1)
    nz = signal.sosfilt(signal.butter(2, [800, 9000], "band", fs=SR, output="sos"), rng.standard_normal(n)) * np.exp(-t * 14)
    nz = nz / (np.abs(nz).max() + 1e-9)
    y = 0.22 * sub + 0.06 * nz
    return np.stack([y, y], axis=1).astype(np.float32)


class Engine:
    def __init__(self, crate, bpm):
        self.bpm = bpm
        self.spb = 60 / bpm * SR
        self.crate = crate
        self.decks = {"A": DeckDSP(), "B": DeckDSP()}
        from pedalboard import Compressor, Limiter, Pedalboard
        self.master = Pedalboard([Compressor(threshold_db=-12, ratio=2.5, attack_ms=8, release_ms=120),
                                  Limiter(threshold_db=-0.8, release_ms=60)])
        self.future = np.zeros((int(64 * self.spb), 2), np.float32)  # echo tails / one-shots spilling forward
        self.bar = 0
        self.fps = 30
        self.tele = []  # per video frame: what every control is doing (drives the stage visuals)

    def _read(self, tr, pos, which):
        src = {"mix": tr.mix, "vox": tr.vox, "inst": tr.inst}[which]
        pos = np.clip(pos, 0, len(src) - 2)
        if np.all(np.diff(pos) == 1):
            i = int(pos[0])
            return np.array(src[i:i + len(pos)])
        i = pos.astype(int)
        fr = (pos - i)[:, None]
        return src[i] * (1 - fr) + src[i + 1] * fr

    def render_bar(self, plan):
        """plan: {"decks": {deck: prog}, "oneshots": [(beat, kind, args)]}. Returns (n, 2) float32."""
        spb = self.spb
        a = int(round(self.bar * 4 * spb))
        n = int(round((self.bar + 1) * 4 * spb)) - a
        out = np.zeros((n, 2), np.float32)
        send_echo = np.zeros((n, 2), np.float32)
        t_beats = np.arange(n) / spb
        f0 = int(np.ceil(a * self.fps / SR))
        fidx = [(f, int(round(f * SR / self.fps)) - a) for f in range(f0, f0 + n) if 0 <= int(round(f * SR / self.fps)) - a < n]
        frames = {f: {"f": f, "decks": {}, "fx": []} for f, _ in fidx}
        for dname, prog in plan["decks"].items():
            dsp = self.decks[dname]
            tr = self.crate[prog["track"]]
            base = (prog["src_bar"] - tr.bar0) * tr.spbar
            pos = base + np.arange(n, dtype=np.float64)
            env = np.ones(n)
            for seg in prog.get("read", []):
                b0, b1, kind = seg[0], seg[1], seg[2]
                m = (t_beats >= b0) & (t_beats < b1)
                k = int(m.sum())
                if not k:
                    continue
                s0 = int(b0 * spb)
                if kind == "roll":
                    size = seg[3] * spb
                    pos[m] = base + s0 + np.mod(np.arange(k), size)
                elif kind == "scratch":
                    p, g = scratch_map(seg[3], k, spb, seg[4] * spb, seg[5] * spb)
                    pos[m], env[m] = base + p, g
                elif kind == "spinback":
                    p, g = spin_map(k, base + s0, back=True)
                    pos[m], env[m] = p, g
                elif kind == "brake":
                    p, g = spin_map(k, base + s0, back=False)
                    pos[m], env[m] = p, g
                elif kind == "mute":
                    env[m] = 0
            st = dsp.state
            curves = {}
            for p in ("gain", "vox", "inst", "low", "mid", "high", "filter", "echo", "reverb"):
                curves[p], st[p] = keyed(prog.get(p), st[p], n, spb)
            touch = np.array([""] * n, dtype=object)
            rsize = np.zeros(n)
            for seg in prog.get("read", []):
                mm = (t_beats >= seg[0]) & (t_beats < seg[1])
                touch[mm] = seg[2] + (":" + seg[3] if seg[2] == "scratch" else "")
                if seg[2] == "roll":
                    rsize[mm] = seg[3]
            for f, i in fidx:
                frames[f]["decks"][dname] = {
                    "track": prog["track"], "angle": float(pos[i] / SR * 200.0) % 360, "env": float(env[i]),
                    "touch": touch[i], "roll": float(rsize[i]),
                    **{k: float(curves[k][i]) for k in ("gain", "vox", "inst", "low", "mid", "high", "filter", "echo", "reverb")}}
            x = (self._read(tr, pos, "vox") * dj.db2lin(curves["vox"])[:, None]
                 + self._read(tr, pos, "inst") * dj.db2lin(curves["inst"])[:, None])
            if prog.get("scratch_dcblock", any(s[2] == "scratch" for s in prog.get("read", []))):
                x = signal.sosfilt(signal.butter(2, 60, "high", fs=SR, output="sos"), x, axis=0)
            x = x * (env * tr.trim)[:, None]
            x = dsp.eq(x, dj.db2lin(curves["low"]), dj.db2lin(curves["mid"]), dj.db2lin(curves["high"]))
            x = dsp.filt(x, curves["filter"])
            x = x * dj.db2lin(curves["gain"])[:, None]
            send_echo += x * curves["echo"][:, None]
            wet = dsp.rev(np.ascontiguousarray((x * curves["reverb"][:, None]).T), SR, reset=False).T
            out += x + 0.5 * wet
        # tempo-synced echo bus (dotted 8th, ping-pong) into the future buffer
        if np.any(send_echo):
            d = int(0.75 * spb)
            g = 1.0
            tap = signal.sosfilt(signal.butter(1, [300, 5000], "band", fs=SR, output="sos"), send_echo, axis=0)
            for r in range(1, 9):
                g *= 0.55
                o = r * d
                seg = tap[:, ::-1] if r % 2 else tap
                self.future[o:o + n] += g * seg[:len(self.future) - o]
        for beat, kind, args in plan.get("oneshots", []):
            o = int(beat * spb)
            fb = int(round((a + o) * self.fps / SR))
            if fb in frames:
                frames[fb]["fx"].append(kind)
            elif kind == "impact":
                self.pending_fx = getattr(self, "pending_fx", []) + [(fb, kind)]
            y = impact(spb) * dj.db2lin(np.array(args.get("gain", -4.0))) if kind == "impact" else \
                dj.noise_riser(0, spb, args["bars"]) * dj.db2lin(np.array(args.get("gain", -12.0)))
            self.future[o:o + len(y)] += y[:len(self.future) - o]
        out += self.future[:n]
        self.future = np.concatenate([self.future[n:], np.zeros((n, 2), np.float32)])
        out = self.master(np.ascontiguousarray(out.T * 0.75), SR, reset=False).T
        out = np.clip(out, -0.97, 0.97)
        for f, i in fidx:
            w = out[max(0, i - 700):i + 700]
            frames[f]["rms"] = float(np.sqrt(np.mean(w ** 2)))
            for fb, k in list(getattr(self, "pending_fx", [])):
                if fb == f:
                    frames[f]["fx"].append(k)
        self.tele.extend(frames[f] for f, _ in fidx)
        self.bar += 1
        return out.astype(np.float32)


# ================================================================ moves -> bar programs

MOVES = {
    # in-track moves (keep the current song going)
    "ride": "Let the song play untouched. Right when the groove and the hook are carrying the moment.",
    "scratch_fill": "Scratch the current song's own vocal hook over the last two beats, then let it continue. A flashy fill on a phrase end.",
    "roll_fill": "Stutter the last beat with a quick loop roll (1/4 then 1/8 beat) then continue. Adds tension on a phrase end.",
    "echo_throw": "Throw the last vocal word into a big echo while the song keeps playing. Classy accent at the end of a vocal line.",
    "filter_dip": "Sweep a low-pass filter down and back up across the bar for a muffled 'underwater' breakdown feel, then snap back.",
    # transitions (change song on the next downbeat)
    "scratch_in": "Cut the vocals of the current song, scratch the NEXT song's hook over its beat for a full bar, then slam the next song in on the 1. The signature hype transition.",
    "chop_cut": "Crossfader chops: rapidly alternate between current and next song every half beat for a bar, landing on the next song's hook. Flashy, energetic.",
    "echo_out_cut": "Throw the current song into echo on the last beat and cut it; the next song slams in on the 1. Clean, punchy.",
    "spinback_cut": "Rewind the current song (spinback) over the last two beats, then drop the next song. Crowd-pleasing classic.",
    "brake_cut": "Vinyl-brake the current song to a stop over the last two beats, then drop the next song. Dramatic.",
    "roll_build_cut": "Loop-roll the current song shrinking 1 → 1/2 → 1/4 → 1/8 beat with a rising filter and noise, then drop the next song. Maximum build-up.",
    "drop_gap_cut": "Full silence on the last beat, then the next song hits with a sub boom. Big impact.",
}
TRANSITIONS = [m for m in MOVES if m.endswith("_cut") or m == "scratch_in"]
FILLS = ["ride", "scratch_fill", "roll_fill", "echo_throw", "filter_dip"]


class Conductor:
    """Code stays in control (phrasing, decks, timing); the brain only makes the typed decisions."""

    def __init__(self, crate_meta, crate, brain, total_bars, bpm, rng):
        self.meta, self.crate, self.brain = crate_meta, crate, brain
        self.total, self.bpm, self.rng = total_bars, bpm, rng
        self.plans = {}  # bar -> plan
        self.log = []
        self.cur = None  # {"deck", "track", "start_bar" (timeline), "src0" (source bar at start)}
        self.played = []
        self.move_hist = []
        self.requests = []
        self.segments = []  # (track, timeline bar where it becomes audible)
        self.scratch_hist = []
        self.avoid_scratch = []
        self.budget_ms = 2 * 240 / bpm * 1000 - 200  # 2-bar lookahead minus render margin
        self.emit = lambda e: None
        self.plays = {}

    # --- helpers
    def deck_prog(self, bar, seg, **kw):
        """Normal playback program for a segment at timeline `bar`."""
        return {"track": seg["track"], "src_bar": seg["src0"] + (bar - seg["start_bar"]), **kw}

    def _plan(self, bar):
        return self.plans.setdefault(bar, {"decks": {}, "oneshots": []})

    def _stop_other(self, bar, deck):
        other = "B" if deck == "A" else "A"
        self._plan(bar)["decks"].pop(other, None)

    def start_segment(self, bar, track, deck, first_prog_extra=None):
        m = self.meta[track]
        seg = {"deck": deck, "track": track, "start_bar": bar, "src0": m["hook"], "len": m["hook_len"]}
        self.cur = seg
        self.played.append(track)
        return seg

    def fill_segment(self, upto):
        """Schedule plain playback of the current segment through bar `upto` (inclusive) where unplanned."""
        s = self.cur
        for b in range(s["start_bar"], upto + 1):
            p = self._plan(b)
            if s["deck"] not in p["decks"]:
                p["decks"][s["deck"]] = self.deck_prog(b, s, gain=[(0, 0)], vox=[(0, 0)], inst=[(0, 0)], low=[(0, 0)],
                                                       mid=[(0, 0)], high=[(0, 0)], filter=[(0, 0)], echo=[(0, 0)], reverb=[(0, 0)])

    # --- state for the brain
    def state(self, bar):
        s = self.cur
        into = bar - s["start_bar"]
        m = self.meta[s["track"]]
        src_bar = s["src0"] + into
        vox = dj.lib(s["track"])["levels"]["vocals"]
        vi = int(src_bar / m.get("time_factor", 1))
        v = vox[vi] if vi < len(vox) else 0
        left = self.total - bar
        phrase_end = (into % 4) == 3
        must_change = into >= s["len"] - 1
        if left <= 1:
            pos = "this is the FINAL bar of the whole mix — end it with style"
        elif must_change:
            pos = "the song's hook is running out: this bar must transition to the next song"
        elif phrase_end and into >= 3:
            pos = f"last bar of a 4-bar phrase ({'the song has played a while — a transition fits well' if into >= 7 else 'the song only just started; a transition is possible but early'})"
        else:
            pos = "middle of a phrase — keep the groove going or add a small accent"
        recent = [h for h in self.move_hist[-4:]]
        st = {
            "gig": "A fast, fun, poppy ~60 second party quick-mix for an Instagram reel. Songs change every 4–8 bars. "
                   "Must feel surprising and hype, with DJ skills on show (scratching, cuts, rolls). Avoid repeating the same move back-to-back.",
            "now_playing": {"song": m["title"], "part": m["hook_desc"], "energy": m["energy"],
                            "vocals_this_bar": "strong vocal" if v >= 6 else "light vocal" if v >= 3 else "instrumental"},
            "timing": pos,
            "mix_progress": "opening" if bar < 6 else "final stretch" if left <= 6 else "middle",
            "recent_moves": recent or ["(none yet)"],
            "songs_already_played": [self.meta[t]["title"] for t in self.played],
        }
        if self.requests:
            st["crowd_request"] = self.requests[-1]
        return st, phrase_end, must_change, left

    # --- decide + schedule bar `bar` (called 2 bars ahead of playback)
    def decide(self, bar):
        if bar in self.plans and self.plans[bar].get("locked"):
            return
        st, phrase_end, must_change, left = self.state(bar)
        into = bar - self.cur["start_bar"]
        if left <= 1:
            options = ["echo_out_cut", "brake_cut", "spinback_cut"]
        elif must_change:
            options = TRANSITIONS
        elif phrase_end and into >= 3:
            options = FILLS + TRANSITIONS
        else:
            options = ["ride", "filter_dip", "echo_throw"] if into % 4 == 1 else ["ride"]
        # variety is enforced in code, not hoped for: drop the moves used recently
        used = [h.split(" ")[0] for h in self.move_hist[-6:] if not h.startswith("ride")]
        last_tr = [h.split(" ")[0] for h in self.move_hist if h.split(" ")[0] in TRANSITIONS][-2:]
        pruned = [o for o in options if o == "ride" or (o not in used[-2:] and o not in last_tr
                                                           and not (o == "filter_dip" and "filter_dip" in used))]
        if len([o for o in pruned if o in TRANSITIONS]) >= 2 or not any(o in TRANSITIONS for o in options):
            options = pruned
        self.avoid_scratch = self.scratch_hist[-2:]
        unplayed = [t for t in self.meta if t not in self.played] or [t for t in self.meta if t != self.cur["track"]]
        t0 = time.perf_counter()
        called = len(options) > 1 or left <= 1
        d = self.brain.decide(st, options, unplayed, self.meta, self.avoid_scratch) if called else \
            {"move": options[0], "next": None, "scratch": "baby", "hype": 2, "ms": 0, "probs": {}}
        d["ms"] = (d.get("ms") or (time.perf_counter() - t0) * 1000) if called else 0
        move = d["move"]
        late = d["ms"] > self.budget_ms
        invalid = move not in options
        if late or invalid:
            move = "ride" if "ride" in options else ("echo_out_cut" if "echo_out_cut" in options else options[0])
        if "scratch" in move:
            self.scratch_hist.append(d.get("scratch") or "baby")
        nxt = d.get("next") if d.get("next") in unplayed else (unplayed[0] if unplayed else None)
        self.move_hist.append(move if move not in TRANSITIONS else f"{move} → {self.meta[nxt]['title'] if nxt else 'end'}")
        self.log.append({"bar": bar, "move": move, "next": nxt, "scratch": d.get("scratch"), "hype": d.get("hype"),
                         "ms": round(d["ms"], 1), "probs": d.get("probs", {}), "options": options,
                         "next_probs": d.get("next_probs", {}), "scratch_probs": d.get("scratch_probs", {}),
                         "conf": d.get("conf"), "decided_at_bar": bar - 2, "deck": self.cur["deck"],
                         "late": late, "invalid": invalid and not late, "wanted": d.get("move"), "error": d.get("error"),
                         "state": st, "track": self.cur["track"]})
        self.apply(bar, move, nxt, d.get("scratch") or "baby", d.get("hype", 2), final=left <= 1)
        if d["ms"]:
            L = self.log[-1]
            self.emit({"type": "decision", "bar": bar, "move": move, "wanted": L["wanted"], "late": late, "invalid": L["invalid"],
                       "ms": round(d["ms"]), "next": self.meta[nxt]["title"] if nxt and move in TRANSITIONS and left > 1 else None,
                       "scratch": d.get("scratch") if "scratch" in move else None, "probs": d.get("probs", {}),
                       "options": options, "budget_ms": round(self.budget_ms)})

    def apply(self, bar, move, nxt, scratch, hype, final=False):
        s = self.cur
        D = s["deck"]
        self.fill_segment(bar)
        p = self._plan(bar)
        prog = p["decks"][D]
        m = self.meta[s["track"]]
        # base values for this bar
        if move == "ride":
            return
        if move == "filter_dip":
            prog["filter"] = [(0, 0), (2, -0.75), (3.75, -0.1), (4, 0)]
            return
        if move == "scratch_fill":
            # stab is in absolute source beats; read segments take it relative to this bar's source start
            prog["read"] = [(2, 4, "scratch", scratch, (m["stab"] - prog["src_bar"] * 4), m["stab_len"])]
            prog["vox"] = [(1.99, 0), (2, 4)]
            prog["inst"] = [(1.99, 0), (2, -60), (4, -60)]
            nx = self._plan(bar + 1)["decks"].setdefault(D, self.deck_prog(bar + 1, s)); nx["inst"] = [(0, 0)]; nx["vox"] = [(0, 0)]
            return
        if move == "roll_fill":
            prog["read"] = [(3, 3.5, "roll", 0.25), (3.5, 4, "roll", 0.125)]
            return
        if move == "echo_throw":
            prog["echo"] = [(3, 0), (3.01, 0.9), (4, 0.9), (4, 0)]
            return
        # ---------------- transitions
        if final:
            if move == "echo_out_cut":
                prog["echo"] = [(2.99, 0), (3, 1), (4, 1)]
                prog["gain"] = [(3.99, 0), (4, -60)]
            elif move == "brake_cut":
                prog["read"] = [(2, 4, "brake")]
                prog["echo"] = [(3.5, 0), (3.6, 0.6)]
            else:
                prog["read"] = [(2, 4, "spinback")]
            prog["reverb"] = [(2, 0), (4, 0.6)]
            p["locked"] = True
            return
        N = "B" if D == "A" else "A"
        nm = self.meta[nxt]
        nb = bar + 1
        k = self.plays.get(nxt, 0)
        self.plays[nxt] = k + 1
        cues = nm.get("cues") or [nm["hook"]]
        cue = cues[k % len(cues)]
        nseg = {"deck": N, "track": nxt, "start_bar": nb, "src0": cue, "len": nm["hook_len"]}
        inprog = {"track": nxt, "src_bar": cue - 1, "gain": [(0, -60)], "vox": [(0, 0)], "inst": [(0, 0)],
                  "low": [(0, 0)], "mid": [(0, 0)], "high": [(0, 0)], "filter": [(0, 0)], "echo": [(0, 0)], "reverb": [(0, 0)]}
        big = hype >= 2
        if move == "scratch_in":
            prog["vox"] = [(0, -60)]
            prog["low"] = [(0, -60)]
            prog["mid"] = [(0, -9)]
            prog["gain"] = [(0, -3)]
            prog["filter"] = [(0, 0.3), (3.5, 0.55)]
            inprog["read"] = [(0, 3.5, "scratch", scratch, nm["stab"] - (cue - 1) * 4, nm["stab_len"]),
                              (3.5, 4, "mute")]
            inprog["gain"] = [(0, 4)]
            inprog["inst"] = [(0, -60)]
            p["decks"][N] = inprog
            p["oneshots"].append((4, "impact", {"gain": -6 if big else -12}))
        elif move == "chop_cut":
            inprog["gain"] = [(0, 0)]
            ph = []
            for i in range(8):
                on = i % 2 == 1
                ph += [(i * 0.5, 0 if on else -60), (i * 0.5 + 0.49, 0 if on else -60)]
            inprog["gain"] = ph
            prog["gain"] = [(b, -60 if v == 0 else 0) for b, v in ph]
            p["decks"][N] = inprog
        elif move == "echo_out_cut":
            prog["echo"] = [(2.99, 0), (3, 1), (4, 1)]
            prog["gain"] = [(2.99, 0), (3, -3), (3.99, -3), (4, -60)]
            prog["read"] = [(3, 4, "roll", 1)]
        elif move == "spinback_cut":
            prog["read"] = [(2, 4, "spinback")]
            p["oneshots"].append((4, "impact", {"gain": -8}))
        elif move == "brake_cut":
            prog["read"] = [(2, 4, "brake")]
            p["oneshots"].append((4, "impact", {"gain": -8}))
        elif move == "roll_build_cut":
            prog["read"] = [(0, 2, "roll", 1), (2, 3, "roll", 0.5), (3, 3.5, "roll", 0.25), (3.5, 4, "roll", 0.125)]
            prog["filter"] = [(0, 0.1), (4, 0.75)]
            p["oneshots"].append((0, "riser", {"bars": 1, "gain": -14}))
            p["oneshots"].append((4, "impact", {"gain": -5}))
        elif move == "drop_gap_cut":
            prog["read"] = [(3, 4, "mute")]
            p["oneshots"].append((4, "impact", {"gain": -4}))
        self.segments.append((nxt, bar if move in ("scratch_in", "chop_cut") else nb))
        # stop outgoing deck after this bar; incoming starts at its hook
        self.plans.setdefault(nb, {"decks": {}, "oneshots": []})
        self.cur = nseg
        self.played.append(nxt)
        self.fill_segment(nb)
        self._plan(nb)["decks"][N]["gain"] = [(0, 0)]


# ================================================================ brains

class JevBrain:
    def __init__(self):
        # TypeSafe direct if we have a key, else OpenRouter's System One passthrough (same request/response shape)
        tk = ROOT / ".typesafe_key"
        if os.environ.get("TYPESAFE_API_KEY") or tk.exists():
            self.URL, self.model = "https://api.typesafe.ai/v1/systemone", "jev-latest"
            self.key = os.environ.get("TYPESAFE_API_KEY") or tk.read_text().strip()
        else:
            self.URL, self.model = "https://openrouter.ai/api/v1/systemone", "typesafe/jev-1.13"
            self.key = os.environ.get("OPENROUTER_API_KEY") or (ROOT / ".openrouter_key").read_text().strip()

    def decide(self, st, options, unplayed, meta, avoid=()):
        styles = {"baby": "simple forward-back, smooth and musical",
                  "chirp": "fader cut on each push: bird-like 'chirp', punchy",
                  "transformer": "fast fader stutter across a slow push: robotic, hype",
                  "scribble": "tense buzzing vibrato on the record: aggressive",
                  "tear": "the push is split in two: rhythmic, funky",
                  "flare": "fader clicks mid-stroke: technical, battle-DJ flavour"}
        styles = {k: v for k, v in styles.items() if k not in avoid}
        q = {
            "move": {"type": "choice",
                     "instructions": "You are the DJ. Pick the move for the upcoming bar that makes this reel most exciting right now, "
                                     "respecting `timing`, avoiding `recent_moves` repeats, and honouring any `crowd_request`.",
                     "criteria": {o: MOVES[o] for o in options}},
            "scratch": {"type": "choice",
                        "instructions": "If this bar involves scratching, which scratch technique sounds best here?",
                        "criteria": styles},
            "hype": {"type": "score", "instructions": "How big should the next moment hit?",
                     "criteria": ["keep it smooth", "steady groove", "hype", "peak — go all out"]},
        }
        if len(unplayed) > 1:
            q["next"] = {"type": "choice",
                         "instructions": "If the DJ changes song now, which song should come next for maximum crowd reaction, "
                                         "given what is playing and the flow so far?",
                         "criteria": {t: f"{meta[t]['title']} — {meta[t]['vibe']}" for t in unplayed}}
        body = json.dumps({"state": st, "model": self.model, "questions": q}).encode()
        req = urllib.request.Request(self.URL, data=body, headers={"Authorization": f"Bearer {self.key}",
                                                                   "Content-Type": "application/json"})
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=5) as r:
            res = json.loads(r.read())
        ms = (time.perf_counter() - t0) * 1000
        A = res["answers"]
        hype_ans = A["hype"]
        hs = hype_ans.get("score")
        return {"move": A["move"]["choice"], "next": A.get("next", {}).get("choice"),
                "scratch": A["scratch"]["choice"], "hype": int(round(hs)) if isinstance(hs, (int, float)) else 2,
                "ms": ms, "probs": A["move"].get("probabilities", {}), "conf": A["move"].get("confidence"),
                "next_probs": A.get("next", {}).get("probabilities", {}), "scratch_probs": A["scratch"].get("probabilities", {}),
                "model": res.get("model")}


class LLMBrain:
    """Any chat model on OpenRouter, asked the same questions as Jev, answering in JSON."""

    def __init__(self, model):
        self.model = model
        self.key = os.environ.get("OPENROUTER_API_KEY") or (ROOT / ".openrouter_key").read_text().strip()

    def decide(self, st, options, unplayed, meta, avoid=()):
        styles = [k for k in SCRATCHES if k not in avoid]
        prompt = (
            "You are a DJ performing live. Decide the move for the upcoming bar. Reply with ONLY a JSON object, no prose:\n"
            '{"move": <one of MOVES>, "next": <one of NEXT_SONGS or null>, "scratch": <one of SCRATCH_STYLES>, "hype": <0-3>}\n\n'
            f"STATE: {json.dumps(st)}\n\nMOVES: {json.dumps({o: MOVES[o] for o in options})}\n\n"
            f"NEXT_SONGS: {json.dumps({t: meta[t]['title'] for t in unplayed})}\n\nSCRATCH_STYLES: {json.dumps(styles)}")
        body = {"model": self.model, "max_tokens": 600, "temperature": 0.8,
                "messages": [{"role": "user", "content": prompt}], "reasoning": {"effort": "low", "exclude": True}}
        req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        t0 = time.perf_counter()
        out = {}
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                res = json.loads(r.read())
            txt = (res["choices"][0]["message"].get("content") or "")
            import re
            m = re.search(r"\{.*\}", txt, re.S)
            out = json.loads(m.group(0)) if m else {}
        except Exception as e:  # a fumbled decision is part of the show
            out = {"error": str(e)[:120]}
        ms = (time.perf_counter() - t0) * 1000
        hype = out.get("hype", 2)
        return {"move": out.get("move"), "next": out.get("next"), "scratch": out.get("scratch") if out.get("scratch") in SCRATCHES else "baby",
                "hype": int(hype) if isinstance(hype, (int, float)) else 2, "ms": ms, "probs": {}, "error": out.get("error")}


def make_brain(spec, rng=None):
    if spec == "jev":
        return JevBrain()
    if spec in ("mock", "random"):
        return MockBrain(rng if rng is not None else np.random.default_rng())
    return LLMBrain(spec)


class MockBrain:
    """Stand-in with the same interface (rules + randomness) for testing without a key."""

    def __init__(self, rng):
        self.rng = rng

    def decide(self, st, options, unplayed, meta, avoid=()):
        w = {o: 1.0 for o in options}
        w["ride"] = w.get("ride", 0) * (3 if "middle" in st["timing"] else 0.6)
        for o in list(w):
            if any(r.startswith(o) for r in st["recent_moves"][-2:]):
                w[o] *= 0.15
        if "scratch_in" in w:
            w["scratch_in"] *= 2.2
        ks = list(w)
        ps = np.array([w[k] for k in ks])
        ps /= ps.sum()
        mv = ks[self.rng.choice(len(ks), p=ps)]
        return {"move": mv, "next": self.rng.choice(unplayed) if unplayed else None,
                "scratch": self.rng.choice([k for k in SCRATCHES if k not in avoid]), "hype": int(self.rng.integers(1, 4)),
                "ms": 0.0, "probs": {k: round(float(p), 3) for k, p in zip(ks, ps)}}


# ================================================================ main loop

def short(title):
    return title.split(" – ", 1)[1] if " – " in title else title


def perform(meta, first, bars, bpm, brain, name, live=False, on_event=None, rng=None, brain_label="jev"):
    """Run a whole set. meta: crate dict (track -> cues). Returns a summary; writes out/<name>.* files."""
    rng = rng if rng is not None else np.random.default_rng(3)
    emit = on_event or (lambda e: None)
    emit({"type": "step", "text": f"time-stretching the cue regions to {bpm:g} bpm"})
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(len(meta)) as ex:
        crate = dict(zip(meta, ex.map(lambda t: Track(t, meta[t], bpm), meta)))
    eng = Engine(crate, bpm)
    C = Conductor(meta, crate, brain, bars, bpm, rng)
    C.emit = emit
    # opener: scratch intro of the first hook over nothing, then drop on bar 1
    seg = C.start_segment(1, first, "A")
    C.plays[first] = 1
    m0 = meta[first]
    C.plans[0] = {"decks": {"A": {"track": first, "src_bar": m0["hook"] - 1, "gain": [(0, 0)], "vox": [(0, 0)],
                                  "inst": [(0, -60)], "low": [(0, 0)], "mid": [(0, 0)], "high": [(0, 0)],
                                  "filter": [(0, 0)], "echo": [(0, 0)], "reverb": [(3, 0), (3.5, 0.5), (4, 0)],
                                  "read": [(0, 3.5, "scratch", "baby", m0["stab"] - (m0["hook"] - 1) * 4, m0["stab_len"]),
                                           (3.5, 4, "mute")]}},
                  "oneshots": [(4, "impact", {"gain": -4})], "locked": True}
    C.fill_segment(1)
    C.segments.append((first, 0))
    C.log.append({"bar": 0, "move": "scratch_intro", "next": first, "scratch": "baby", "ms": 0, "probs": {}, "track": first})
    C.move_hist.append(f"scratch_intro → {m0['title']}")
    LOOK = 2
    OUT.mkdir(exist_ok=True)
    rec = []
    render_ms = []
    audio_q = queue.Queue(maxsize=LOOK + 2)
    stream = None
    if live:
        import sounddevice as sd
        buf = {"x": np.zeros((0, 2), np.float32)}

        def cb(outdata, frames, t, status):
            while len(buf["x"]) < frames:
                try:
                    buf["x"] = np.concatenate([buf["x"], audio_q.get_nowait()])
                except queue.Empty:
                    break
            k = min(frames, len(buf["x"]))
            outdata[:k] = buf["x"][:k]
            outdata[k:] = 0
            buf["x"] = buf["x"][k:]
        stream = sd.OutputStream(samplerate=SR, channels=2, callback=cb, blocksize=1024)

        def reader():
            for line in sys.stdin:
                if line.strip():
                    C.requests.append(line.strip())
                    print(f"  crowd request: {line.strip()!r}", file=sys.stderr)
        threading.Thread(target=reader, daemon=True).start()
    bar_sec = 240 / bpm
    for b in range(1, min(LOOK, bars)):
        C.decide(b)
    t_start = None
    for b in range(bars):
        nb = b + LOOK
        if nb < bars:
            C.decide(nb)  # the decision for two bars ahead happens while bar b plays
        if b not in C.plans or not C.plans[b]["decks"]:
            C.fill_segment(b)
        tr0 = time.perf_counter()
        x = eng.render_bar(C.plans[b])
        render_ms.append((time.perf_counter() - tr0) * 1000)
        rec.append(x)
        d = next((l for l in C.log if l["bar"] == nb), None)
        if d:
            nxt = "(finale)" if nb == bars - 1 else f" → {meta[d['next']]['title']}" if d["move"] in TRANSITIONS and d.get("next") else ""
            print(f"bar {b:>2} playing | decided bar {nb:>2}: {d['move']:<15}{nxt:<28} "
                  f"{d['ms']:6.0f} ms  hype={d.get('hype')} scratch={d.get('scratch')}", file=sys.stderr)
        if live:
            audio_q.put(x)
            if b == LOOK - 1:
                stream.start()
                t_start = time.time()
    # tail (echo/reverb ring-out)
    tail = eng.render_bar({"decks": {}, "oneshots": []})
    rec.append(tail * np.linspace(1, 0, len(tail))[:, None])
    y = np.concatenate(rec)
    if live:
        audio_q.put(rec[-1])
        while not audio_q.empty():
            time.sleep(0.2)
        time.sleep(bar_sec * 1.2)
        stream.stop()
    sf.write(OUT / f"{name}.wav", y, SR)
    import subprocess
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(OUT / f"{name}.wav"), "-b:a", "320k", str(OUT / f"{name}.mp3")])
    (OUT / f"{name}.meta.json").write_text(json.dumps(meta))
    (OUT / f"{name}.decisions.json").write_text(json.dumps({"bpm": bpm, "bars": bars, "brain": brain_label, "model": getattr(brain, "model", brain_label),
                                                            "log": C.log}, indent=1, default=str))
    # reel description: lanes + captions (move + the brain's latency/confidence)
    NAMES = {"scratch_intro": "scratch intro", "scratch_in": "{s} scratch in", "chop_cut": "crossfader chops",
             "echo_out_cut": "echo out", "spinback_cut": "spinback", "brake_cut": "vinyl brake",
             "roll_build_cut": "loop roll build", "drop_gap_cut": "drop gap", "scratch_fill": "{s} scratch fill",
             "roll_fill": "roll fill", "echo_throw": "echo throw", "filter_dip": "filter dip"}
    clips, moves = [], []
    for i, (tr, at) in enumerate(C.segments):
        end = C.segments[i + 1][1] + (1 if i + 1 < len(C.segments) and C.segments[i + 1][1] < at + 1 else 0) \
            if i + 1 < len(C.segments) else bars
        clips.append({"track": short(meta[tr]["title"]).lower(), "at": at, "bars": max(1, end - at + (1 if i + 1 < len(C.segments) else 0))})
    for l in C.log:
        if l["move"] == "ride":
            continue
        txt = NAMES.get(l["move"], l["move"]).format(s=l.get("scratch") or "")
        if l["move"] in TRANSITIONS and l["bar"] < bars - 1 and l.get("next"):
            txt += " → " + short(meta[l["next"]]["title"])
        moves.append({"at": l["bar"], "text": txt.strip()})
        if True and l["ms"]:
            p = l["probs"].get(l["move"]) if isinstance(l["probs"], dict) else None
            moves.append({"at": l["bar"], "text": f"{brain_label} · {l['ms']:.0f} ms" + (f" · {p*100:.0f}% sure" if p else "")})
    with open(OUT / f"{name}.tele.json", "w") as fh:
        json.dump({"fps": eng.fps, "bpm": bpm, "frames": eng.tele}, fh)
    (OUT / f"{name}.reel.json").write_text(json.dumps({"bpm": bpm, "clips": clips, "moves": moves}, indent=1))
    lat = [l["ms"] for l in C.log if l["ms"]]
    print(f"\n{name}: {len(y)/SR:.1f}s, {len(C.log)} decisions, songs: {' → '.join(meta[t]['title'] for t in C.played)}"
          + f"\nrender per bar: median {np.median(render_ms):.0f} ms, max {max(render_ms):.0f} ms"
          + (f"\nbrain latency: median {np.median(lat):.0f} ms, max {max(lat):.0f} ms (bar = {bar_sec*1000:.0f} ms)" if lat else ""),
          file=sys.stderr)

    return {"name": name, "seconds": round(len(y) / SR, 1), "decisions": len(lat), "late": sum(1 for l in C.log if l.get("late")),
            "median_ms": float(np.median(lat)) if lat else 0, "max_ms": float(max(lat)) if lat else 0,
            "songs": [meta[t]["title"] for t in C.played]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brain", default="jev")
    ap.add_argument("--bars", type=int, default=28)
    ap.add_argument("--bpm", type=float, default=104)
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--name", default=None)
    ap.add_argument("--first", default=None)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    meta = json.loads((ROOT / "crate.json").read_text())
    brain = make_brain(args.brain, rng)
    perform(meta, args.first or list(meta)[0], args.bars, args.bpm, brain, args.name or f"{args.brain}_{int(time.time())}",
            live=args.live, rng=rng, brain_label=args.brain)


if __name__ == "__main__":
    main()
