#!/usr/bin/env python3
"""AI DJ harness — DJ operations as agent tools.

Commands (the agent's "tools"):
  dj.py analyze                 analyze every track in tracks/ (beats, bars, key, per-bar stem energy)
  dj.py crate                   list tracks: bpm, key, camelot, bars
  dj.py inspect <track>         per-bar energy grid (drums/bass/vocals/other) to find drops, breaks, acapellas
  dj.py render <set.json>       perform the set -> out/<name>.wav/.mp3 + spectrogram png + listen report
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

ROOT = Path(__file__).parent
TRACKS, STEMS, LIB, CACHE, OUT = (ROOT / d for d in ("tracks", "stems/htdemucs", "library", "cache", "out"))
SR = 44100
STEM_NAMES = ["drums", "bass", "other", "vocals"]


# ---------------------------------------------------------------- analysis

def _load(path):
    y, sr = sf.read(path, dtype="float32", always_2d=True)
    if sr != SR:
        raise ValueError(f"{path} is {sr} Hz, expected {SR}")
    return y


def _key(y_mono):
    import librosa
    chroma = librosa.feature.chroma_cqt(y=y_mono, sr=SR, hop_length=4096).mean(axis=1)
    major = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    best = max(((np.corrcoef(chroma, np.roll(p, i))[0, 1], i, m)
                for i in range(12) for p, m in ((major, "maj"), (minor, "min"))))
    _, tonic, mode = best
    # Camelot: minor A-keys, major B-keys
    cam_major = {0: 8, 7: 9, 2: 10, 9: 11, 4: 12, 11: 1, 6: 2, 1: 3, 8: 4, 3: 5, 10: 6, 5: 7}
    cam = f"{cam_major[(tonic + 3) % 12]}A" if mode == "min" else f"{cam_major[tonic]}B"
    return f"{names[tonic]} {mode}", cam


def analyze_track(name):
    from beat_this.inference import File2Beats
    path = TRACKS / f"{name}.wav"
    y = _load(path)
    beats, downbeats = File2Beats(device="mps", dbn=False)(str(path))
    # Dance music is quantized: fit a straight beat grid (robust to missed/extra detections).
    # Iteratively refit: start from a local window, extend, drop outliers (breakdowns/half-time detections).
    d = np.diff(beats)
    mid = len(beats) // 2
    slope, icpt = np.median(d), beats[mid]
    for w in [16, 32, 64, 128, 256, 512, 10**6]:
        for _ in range(3):
            idx = np.round((beats - icpt) / slope)
            resid = beats - (icpt + slope * idx)
            keep = (np.abs(idx) <= w) & (np.abs(resid) < max(0.015, 3 * np.median(np.abs(resid[np.abs(idx) <= w]))))
            slope, icpt = np.polyfit(idx[keep], beats[keep], 1)
    idx = np.round((beats - icpt) / slope)
    resid = (beats - (icpt + slope * idx))[keep]
    bpm = 60.0 / slope
    # Which beat phase (mod 4) carries the downbeats?
    db_idx = np.round((downbeats - icpt) / slope).astype(int)
    phase = int(np.bincount(db_idx % 4, minlength=4).argmax())
    first_db = icpt + phase * slope
    while first_db - 4 * slope > 0:
        first_db -= 4 * slope
    n_bars = int((len(y) / SR - first_db) // (4 * slope))

    stems = {s: _load(STEMS / name / f"{s}.wav") for s in STEM_NAMES}
    bar_len = 4 * slope

    def per_bar(sig):
        out = []
        for b in range(n_bars):
            a = int((first_db + b * bar_len) * SR)
            seg = sig[a:a + int(bar_len * SR)]
            out.append(float(np.sqrt(np.mean(seg ** 2)) + 1e-9))
        return np.array(out)

    grid = {"mix": per_bar(y)} | {s: per_bar(stems[s]) for s in STEM_NAMES}
    # 0-9 levels relative to the track's own loudest bar per stem (floor at -30 dB)
    levels = {}
    for k, v in grid.items():
        db = 20 * np.log10(v / v.max())
        levels[k] = [int(np.clip(round((d + 30) / 30 * 9), 0, 9)) for d in db]
    # vocals: absolute-ish so an instrumental track shows zeros
    vdb = 20 * np.log10(grid["vocals"] / grid["mix"].max())
    levels["vocals"] = [int(np.clip(round((d + 36) / 30 * 9), 0, 9)) for d in vdb]

    key, cam = _key((stems["other"] + stems["bass"]).mean(axis=1))
    info = {"name": name, "bpm": round(bpm, 2), "key": key, "camelot": cam,
            "first_downbeat": round(first_db, 4), "beat_sec": slope, "bars": n_bars,
            "duration": round(len(y) / SR, 1), "grid_jitter_ms": round(float(resid.std() * 1000), 1),
            "levels": levels}
    LIB.mkdir(exist_ok=True)
    (LIB / f"{name}.json").write_text(json.dumps(info))
    return info


def lib(name):
    return json.loads((LIB / f"{name}.json").read_text())


def cmd_crate():
    for p in sorted(LIB.glob("*.json")):
        t = json.loads(p.read_text())
        print(f"{t['name']:<16} {t['bpm']:>7.2f} bpm  {t['key']:<7} ({t['camelot']:>3})  "
              f"{t['bars']:>3} bars  {t['duration']:>5.0f}s  grid jitter {t['grid_jitter_ms']}ms")


def cmd_inspect(name):
    t = lib(name)
    print(f"{name}: {t['bpm']} bpm, {t['key']} ({t['camelot']}), {t['bars']} bars (bar = {4*t['beat_sec']:.2f}s)")
    print("levels 0-9 per bar; bars numbered from 0. 'vocals' is absolute (0 = no vocal).")
    L = t["levels"]
    for start in range(0, t["bars"], 64):
        end = min(start + 64, t["bars"])
        ruler = "".join(str((b // 10) % 10) if b % 8 == 0 else " " for b in range(start, end))
        ruler2 = "".join(str(b % 10) if b % 8 == 0 else "·" for b in range(start, end))
        print(f"\n{'bar':>7} {ruler}\n{'':>7} {ruler2}")
        for k in ["mix", "drums", "bass", "other", "vocals"]:
            print(f"{k:>7} " + "".join(str(x) for x in L[k][start:end]))


# ---------------------------------------------------------------- DSP helpers

def _hash(*a):
    return hashlib.md5(json.dumps(a, sort_keys=True).encode()).hexdigest()[:16]


def stretched(track, stem, from_bar, bars, bpm, pitch):
    """Source audio for [from_bar, from_bar+bars) warped onto the master grid (cached)."""
    t = lib(track)
    CACHE.mkdir(exist_ok=True)
    key = _hash(track, stem, from_bar, bars, bpm, pitch, "v2")
    cp = CACHE / f"{key}.npy"
    if cp.exists():
        return np.load(cp)
    src = _load(TRACKS / f"{track}.wav" if stem == "mix" else STEMS / track / f"{stem}.wav")
    bar_sec = 4 * t["beat_sec"]
    pad = 0.25  # seconds of context either side so the stretcher has no edge artifacts
    a = t["first_downbeat"] + from_bar * bar_sec
    a0 = max(0, int((a - pad) * SR))
    b0 = int((a + bars * bar_sec + pad) * SR)
    seg = src[a0:b0]
    if len(seg) < b0 - a0:
        seg = np.pad(seg, ((0, b0 - a0 - len(seg)), (0, 0)))
    ratio = bpm / t["bpm"]  # >1 = faster
    if abs(ratio - 1) > 1e-4 or pitch:
        import pyrubberband as prb
        seg = prb.time_stretch(seg, SR, ratio, rbargs={"--fine": "", **({"--pitch": str(pitch)} if pitch else {})})
    lead = int(round((a - a0 / SR) * SR / ratio))
    n = int(round(bars * 4 * 60 / bpm * SR))
    out = seg[lead:lead + n]
    if len(out) < n:
        out = np.pad(out, ((0, n - len(out)), (0, 0)))
    np.save(cp, out.astype(np.float32))
    return out


def curve(keys, n, spb, t0_beats, default):
    """Automation keyframes [[bar, value], ...] (timeline bars) -> per-sample array over the clip."""
    if not keys:
        return np.full(n, default, dtype=np.float32)
    keys = sorted(keys, key=lambda k: k[0])
    xs = np.array([(k[0] * 4 - t0_beats) * spb for k in keys])
    ys = np.array([k[1] for k in keys], dtype=np.float32)
    # np.interp needs strictly usable xs; nudge duplicates so [x,a],[x,b] is a hard jump
    for i in range(1, len(xs)):
        if xs[i] <= xs[i - 1]:
            xs[i] = xs[i - 1] + 1
    return np.interp(np.arange(n), xs, ys).astype(np.float32)


def db2lin(db):
    return np.where(db <= -59, 0.0, 10 ** (db / 20)).astype(np.float32)


_SOS = {"lo": signal.butter(4, 220, "low", fs=SR, output="sos"),
        "hi": signal.butter(4, 2800, "high", fs=SR, output="sos")}


def eq3(x, low, mid, high):
    """DJ-mixer style isolator: split into bands (zero phase so they sum flat), gain each band."""
    lo = signal.sosfiltfilt(_SOS["lo"], x, axis=0)
    hi = signal.sosfiltfilt(_SOS["hi"], x, axis=0)
    md = x - lo - hi
    return lo * low[:, None] + md * mid[:, None] + hi * high[:, None]


def dj_filter(x, knob):
    """One-knob DJ filter: knob<0 low-pass sweep, knob>0 high-pass sweep, 0 = bypass. Resonant."""
    if not np.any(np.abs(knob) > 0.01):
        return x
    from pedalboard import LadderFilter
    lp = LadderFilter(mode=LadderFilter.Mode.LPF24, cutoff_hz=20000, resonance=0.35)
    hp = LadderFilter(mode=LadderFilter.Mode.HPF24, cutoff_hz=20, resonance=0.35)
    out = np.empty_like(x)
    blk = 256
    for i in range(0, len(x), blk):
        k = float(knob[i])
        chunk = x[i:i + blk]
        lp.cutoff_hz = float(20000 * (40 / 20000) ** max(0.0, -k)) if k < 0 else 20000
        hp.cutoff_hz = float(20 * (8000 / 20) ** max(0.0, k)) if k > 0 else 20
        y = lp(chunk.T, SR, reset=False)
        y = hp(y, SR, reset=False)
        out[i:i + blk] = y.T if abs(k) > 0.01 else chunk
    return out


def send_delay(x, amount, spb, beats=0.75, feedback=0.55, repeats=10):
    """Tempo-synced ping-pong-ish echo send. Returns wet signal only."""
    if not np.any(amount > 0.001):
        return np.zeros_like(x)
    src = x * amount[:, None]
    d = int(beats * spb)
    wet = np.zeros((len(x) + d * repeats, 2), dtype=np.float32)
    g = 1.0
    lp = signal.butter(1, 5000, "low", fs=SR, output="sos")
    hp = signal.butter(1, 300, "high", fs=SR, output="sos")
    tap = signal.sosfilt(hp, signal.sosfilt(lp, src, axis=0), axis=0)
    for r in range(1, repeats + 1):
        g *= feedback
        s = tap[:, ::-1] if r % 2 else tap  # alternate L/R
        wet[r * d:r * d + len(x)] += g * s
    return wet[:len(x)]


def send_reverb(x, amount):
    if not np.any(amount > 0.001):
        return np.zeros_like(x)
    from pedalboard import Reverb
    rv = Reverb(room_size=0.9, damping=0.4, wet_level=1.0, dry_level=0.0, width=1.0)
    return rv((x * amount[:, None]).T, SR).T


# ---------------------------------------------------------------- performance FX

def fx_loop_roll(x, spb, t0, at, bars, size):
    """Slip-mode loop roll: from `at` for `bars`, repeat a `size`-beat slice captured at `at`."""
    a = int((at * 4 - t0) * spb)
    L = int(bars * 4 * spb)
    s = max(64, int(size * spb))
    if a < 0 or a >= len(x):
        return x
    sl = x[a:a + s].copy()
    fade = min(64, s // 4)
    sl[:fade] *= np.linspace(0, 1, fade)[:, None]
    sl[-fade:] *= np.linspace(1, 0, fade)[:, None]
    reps = np.tile(sl, (L // s + 1, 1))[:min(L, len(x) - a)]
    x = x.copy()
    x[a:a + len(reps)] = reps
    return x


def fx_brake(x, spb, t0, at, beats):
    """Vinyl brake: platter slows to a stop over `beats`, then silence."""
    a = int((at * 4 - t0) * spb)
    if a < 0 or a >= len(x):
        return x
    n = int(beats * spb)
    speed = np.linspace(1, 0, n) ** 1.3
    pos = a + np.cumsum(speed)
    pos = pos[pos < len(x) - 1]
    y = np.stack([np.interp(pos, np.arange(len(x)), x[:, c]) for c in range(2)], axis=1)
    y *= np.linspace(1, 0.2, len(y))[:, None]
    x = x.copy()
    x[a:a + len(y)] = y
    x[a + len(y):] = 0
    return x


def fx_spinback(x, spb, t0, at, beats):
    """Rewind: audio before `at` played backwards, accelerating, over `beats`; silence after."""
    a = int((at * 4 - t0) * spb)
    n = int(beats * spb)
    if a <= 0:
        return x
    speed = 1 + 5 * np.linspace(0, 1, n) ** 2
    pos = a - np.cumsum(speed)
    pos = pos[pos > 0]
    y = np.stack([np.interp(pos, np.arange(len(x)), x[:, c]) for c in range(2)], axis=1)
    y *= np.linspace(1, 0, len(y))[:, None]
    x = x.copy()
    end = min(len(x), a + len(y))
    x[a:end] = y[:end - a]
    x[end:] = 0
    return x


def fx_gate(x, spb, t0, at, bars, rate):
    """Trance gate / stutter: chop audio on and off every `rate` beats."""
    a = int((at * 4 - t0) * spb)
    b = min(len(x), a + int(bars * 4 * spb))
    if a < 0 or a >= len(x):
        return x
    ph = (np.arange(b - a) % int(rate * spb)) / (rate * spb)
    env = np.clip((0.5 - ph) * 40, 0, 1)
    x = x.copy()
    x[a:b] *= env[:, None]
    return x


def noise_riser(n, spb, bars):
    """White-noise sweep (DJ mixer 'noise' FX): high-passed noise rising in cutoff and level."""
    L = int(bars * 4 * spb)
    rng = np.random.default_rng(7)
    nz = rng.standard_normal((L, 2)).astype(np.float32) * 0.25
    knob = np.linspace(0.05, 0.95, L)
    y = dj_filter(nz, knob)
    y *= (np.linspace(0, 1, L) ** 2)[:, None]
    return y


# ---------------------------------------------------------------- render

def render(set_path):
    S = json.loads(Path(set_path).read_text())
    bpm = S["bpm"]
    spb = 60 / bpm * SR  # samples per beat
    total_bars = S.get("bars") or max(c["at"] + c["bars"] for c in S["clips"])
    tail = 8  # beats of FX tail after the last bar
    N = int((total_bars * 4 + tail) * spb)
    mix = np.zeros((N, 2), dtype=np.float32)
    lanes = []
    for c in S["clips"]:
        t0 = c["at"] * 4
        n = int(round(c["bars"] * 4 * spb))
        stems = c.get("stems", "mix")
        auto = c.get("auto", {})
        tn = n + int(tail * spb)
        if stems == "mix" and not any(s in auto for s in STEM_NAMES):
            x = stretched(c["track"], "mix", c["from_bar"], c["bars"], bpm, c.get("pitch", 0))
        else:
            use = STEM_NAMES if stems == "mix" else stems
            x = sum(stretched(c["track"], s, c["from_bar"], c["bars"], bpm, c.get("pitch", 0))
                    * db2lin(curve(auto.get(s), n, spb, t0, 0.0))[:, None] for s in use)
        # performance FX operate on the deck output (slip mode), in listed order
        for f in c.get("fx", []):
            if f["type"] == "loop_roll":
                x = fx_loop_roll(x, spb, t0, f["at"], f["bars"], f["size"])
            elif f["type"] == "brake":
                x = fx_brake(x, spb, t0, f["at"], f.get("beats", 2))
            elif f["type"] == "spinback":
                x = fx_spinback(x, spb, t0, f["at"], f.get("beats", 2))
            elif f["type"] == "gate":
                x = fx_gate(x, spb, t0, f["at"], f["bars"], f.get("rate", 0.25))
            elif f["type"] == "echo_out":
                # throw the echo send up for one beat, cut the deck -> tail rings out in time
                auto.setdefault("echo", []).extend([[f["at"] - 0.25, 0], [f["at"] - 0.25, 1], [f["at"], 1], [f["at"], 0]])
                auto.setdefault("gain", []).extend([[f["at"], 0], [f["at"], -60]])
        # EQ -> filter -> fader, then sends (post-fader) with tails
        x = np.pad(x, ((0, tn - n), (0, 0)))
        x = eq3(x, db2lin(curve(auto.get("low"), tn, spb, t0, 0.0)),
                db2lin(curve(auto.get("mid"), tn, spb, t0, 0.0)),
                db2lin(curve(auto.get("high"), tn, spb, t0, 0.0)))
        x = dj_filter(x, curve(auto.get("filter"), tn, spb, t0, 0.0))
        g = db2lin(curve(auto.get("gain"), tn, spb, t0, 0.0))
        g[n:] = 0  # deck stops at clip end; only send tails continue
        x = x * g[:, None]
        e = curve(auto.get("echo"), tn, spb, t0, 0.0)
        e[n:] = 0
        r = curve(auto.get("reverb"), tn, spb, t0, 0.0)
        r[n:] = 0
        x = x + send_delay(x, e, spb) + 0.6 * send_reverb(x, r)
        a = int(t0 * spb)
        x = x[:N - a]
        # 3ms declick at clip edges
        k = int(0.003 * SR)
        x[:k] *= np.linspace(0, 1, k)[:, None]
        mix[a:a + len(x)] += x
        lanes.append((c.get("id", c["track"]), c["at"], c["at"] + c["bars"], c["track"]))
    for ev in S.get("events", []):
        if ev["type"] == "noise_riser":
            y = noise_riser(N, spb, ev["bars"]) * db2lin(np.array(ev.get("gain", -6.0)))
            a = int(ev["at"] * 4 * spb)
            mix[a:a + len(y)] += y[:N - a]
    # master bus: glue comp + limiter, then loudness to ~-9 LUFS-ish for reels
    from pedalboard import Compressor, Limiter, Pedalboard
    master = Pedalboard([Compressor(threshold_db=-14, ratio=2.5, attack_ms=10, release_ms=120),
                         Limiter(threshold_db=-1.0, release_ms=80)])
    pre_peak = float(np.abs(mix).max())
    rms = np.sqrt(np.mean(mix ** 2))
    mix *= 10 ** (-12 / 20) / max(rms, 1e-6)
    out = master(mix.T, SR).T
    OUT.mkdir(exist_ok=True)
    name = Path(set_path).stem
    wav = OUT / f"{name}.wav"
    sf.write(wav, out, SR)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-b:a", "320k", str(OUT / f"{name}.mp3")], check=True)
    report = listen(out, S, spb, total_bars, lanes, pre_peak)
    spectro(out, spb, total_bars, lanes, OUT / f"{name}.png", S)
    (OUT / f"{name}.report.txt").write_text(report)
    print(report)
    print(f"\nrendered -> {OUT / (name + '.mp3')}  ({len(out)/SR:.1f}s)\nspectrogram -> {OUT / (name + '.png')}")


def listen(out, S, spb, total_bars, lanes, pre_peak):
    """Machine 'ears': per-bar loudness/low-end/brightness + clash warnings, as text for the agent."""
    bar = int(4 * spb)
    lo_sos = signal.butter(4, 150, "low", fs=SR, output="sos")
    lo = signal.sosfilt(lo_sos, out.mean(axis=1))
    rows, warn = [], []
    for b in range(int(np.ceil(total_bars))):
        seg = out[b * bar:(b + 1) * bar].mean(axis=1)
        if len(seg) == 0:
            break
        db = 20 * np.log10(np.sqrt(np.mean(seg ** 2)) + 1e-9)
        ldb = 20 * np.log10(np.sqrt(np.mean(lo[b * bar:(b + 1) * bar] ** 2)) + 1e-9)
        spec = np.abs(np.fft.rfft(seg))
        cent = float((spec * np.fft.rfftfreq(len(seg), 1 / SR)).sum() / (spec.sum() + 1e-9))
        active = [l[0] for l in lanes if l[1] <= b < l[2]]
        rows.append(f"bar {b:>3}  {db:6.1f} dB  low {ldb:6.1f} dB  bright {cent:5.0f} Hz  {'█' * max(0, int((db + 30) / 1.5)):<20} {' + '.join(active)}")
    # clash heuristics from the plan itself
    for i, c1 in enumerate(S["clips"]):
        for c2 in S["clips"][i + 1:]:
            lo_b, hi_b = max(c1["at"], c2["at"]), min(c1["at"] + c1["bars"], c2["at"] + c2["bars"])
            if hi_b - lo_b <= 0:
                continue
            def full_low(c, b):
                a = c.get("auto", {})
                v = curve(a.get("low"), 1, 1, b * 4, 0.0)[0]
                bs = c.get("stems", "mix")
                has_bass = bs == "mix" or "bass" in bs or "drums" in bs
                return has_bass and v > -10
            def vox(c, b):
                a = c.get("auto", {})
                bs = c.get("stems", "mix")
                v = curve(a.get("vocals"), 1, 1, b * 4, 0.0)[0]
                lv = lib(c["track"])["levels"]["vocals"]
                src = int(c["from_bar"] + (b - c["at"]))
                return (bs == "mix" or "vocals" in bs) and v > -10 and 0 <= src < len(lv) and lv[src] >= 5
            clash_low = [b for b in np.arange(lo_b, hi_b, 1.0) if full_low(c1, b) and full_low(c2, b)]
            clash_vox = [b for b in np.arange(lo_b, hi_b, 1.0) if vox(c1, b) and vox(c2, b)]
            if len(clash_low) > 1:
                warn.append(f"LOW-END CLASH {c1.get('id')} x {c2.get('id')}: both basslines full on bars {clash_low[0]:g}-{clash_low[-1]:g} (swap/kill one's low EQ)")
            if len(clash_vox) > 1:
                warn.append(f"VOCAL CLASH {c1.get('id')} x {c2.get('id')}: two vocals over each other bars {clash_vox[0]:g}-{clash_vox[-1]:g}")
            k1, k2 = lib(c1["track"])["camelot"], lib(c2["track"])["camelot"]
            if not camelot_ok(k1, c1.get("pitch", 0), k2, c2.get("pitch", 0)):
                warn.append(f"KEY: {c1.get('id')} ({k1}{'+%d' % c1.get('pitch', 0) if c1.get('pitch') else ''}) and {c2.get('id')} ({k2}{'+%d' % c2.get('pitch', 0) if c2.get('pitch') else ''}) overlap but are not harmonically adjacent")
    for c in S["clips"]:
        t = lib(c["track"])
        r = S["bpm"] / t["bpm"]
        if abs(r - 1) > 0.08:
            warn.append(f"STRETCH {c.get('id')}: {t['bpm']} -> {S['bpm']} bpm is {100*(r-1):+.0f}% (audible artifacts likely)")
        if c["from_bar"] + c["bars"] > t["bars"]:
            warn.append(f"RANGE {c.get('id')}: from_bar+bars exceeds track length ({t['bars']} bars)")
    head = [f"LISTEN REPORT  {S['bpm']} bpm, {total_bars} bars = {total_bars*4*60/S['bpm']:.1f}s, pre-master peak {20*np.log10(pre_peak+1e-9):.1f} dBFS"]
    return "\n".join(head + ["", *rows, "", "WARNINGS:" if warn else "no warnings", *warn])


def camelot_ok(k1, p1, k2, p2):
    def shift(k, p):
        n, l = int(k[:-1]), k[-1]
        return (n - 1 + 7 * p) % 12 + 1, l  # +1 semitone = +7 on the wheel
    (n1, l1), (n2, l2) = shift(k1, p1), shift(k2, p2)
    d = min((n1 - n2) % 12, (n2 - n1) % 12)
    return (d == 0) or (d == 1 and l1 == l2)


def spectro(out, spb, total_bars, lanes, path, S):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    mono = out.mean(axis=1)
    f, t, Z = signal.spectrogram(mono, SR, nperseg=4096, noverlap=3072)
    fig, (ax, ax2) = plt.subplots(2, 1, figsize=(16, 7), height_ratios=[3, 1], sharex=True)
    ax.pcolormesh(t * S["bpm"] / 240, f, 10 * np.log10(Z + 1e-12), shading="auto", cmap="magma", vmin=-110, vmax=-30)
    ax.set_yscale("symlog", linthresh=200)
    ax.set_ylim(30, 16000)
    ax.set_ylabel("Hz")
    for b in range(0, int(total_bars) + 1, 4):
        ax.axvline(b, color="w", lw=0.4, alpha=0.4)
    for i, (cid, a, b, tr) in enumerate(lanes):
        ax2.barh(i, b - a, left=a, color=f"C{i % 10}")
        ax2.text(a + 0.2, i, f"{cid}: {tr}", va="center", fontsize=8, color="k")
    ax2.set_yticks([])
    ax2.set_xlabel("bar")
    fig.tight_layout()
    fig.savefig(path, dpi=80)
    plt.close(fig)


if __name__ == "__main__":
    cmd, *args = sys.argv[1:] or ["help"]
    if cmd == "analyze":
        names = args or [p.stem for p in sorted(TRACKS.glob("*.wav"))]
        for nm in names:
            i = analyze_track(nm)
            print(f"{nm}: {i['bpm']} bpm {i['key']} ({i['camelot']}) {i['bars']} bars jitter {i['grid_jitter_ms']}ms")
    elif cmd == "crate":
        cmd_crate()
    elif cmd == "inspect":
        cmd_inspect(args[0])
    elif cmd == "render":
        render(args[0])
    else:
        print(__doc__)
