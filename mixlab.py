"""Any-two-songs pipeline: YouTube search -> download -> stems -> beat grid -> auto hot cues -> perform -> stage video."""
import json
import math
import re
import subprocess
import sys
import threading
from pathlib import Path

import numpy as np

import dj

ROOT = Path(__file__).parent
PY = sys.executable
_lock = threading.Lock()  # one GPU-heavy job at a time


def search(q, n=6):
    r = subprocess.run(["yt-dlp", "--flat-playlist", "-J", "--no-warnings", f"ytsearch{n}:{q}"],
                       capture_output=True, text=True, timeout=40)
    data = json.loads(r.stdout or "{}")
    out = []
    for e in data.get("entries", []):
        if not e or not e.get("id"):
            continue
        out.append({"id": e["id"], "title": e.get("title", ""), "channel": e.get("channel") or e.get("uploader") or "",
                    "duration": e.get("duration") or 0,
                    "thumb": f"https://i.ytimg.com/vi/{e['id']}/hqdefault.jpg"})
    return out


def clean_title(info):
    if info.get("track") and info.get("artist"):
        return f"{info['artist'].split(',')[0]} – {info['track']}"
    t = re.sub(r"[\(\[][^\)\]]*[\)\]]", "", info.get("title", "")).strip()
    t = re.sub(r"\s*(official|lyrics?|audio|video|visuali[sz]er|hd|4k)\b.*$", "", t, flags=re.I).strip(" -|")
    if " - " in t:
        a, b = t.split(" - ", 1)
        return f"{a.strip()} – {b.strip()}"
    return f"{info.get('channel', '').replace(' - Topic', '')} – {t}"


def fetch(vid, emit):
    name = f"yt_{vid}"
    wav = dj.TRACKS / f"{name}.wav"
    info_p = dj.LIB / f"{name}.info.json"
    if not wav.exists():
        emit({"type": "step", "text": f"downloading {vid} from YouTube"})
        r = subprocess.run(["yt-dlp", "-q", "--no-warnings", "-x", "--audio-format", "wav", "--postprocessor-args", "-ar 44100 -ac 2",
                            "--write-info-json", "-o", str(dj.TRACKS / f"{name}.%(ext)s"), f"https://www.youtube.com/watch?v={vid}"],
                           capture_output=True, text=True, timeout=300)
        if not wav.exists():
            raise RuntimeError(f"download failed: {r.stderr[-300:]}")
        ij = dj.TRACKS / f"{name}.info.json"
        dj.LIB.mkdir(exist_ok=True)
        if ij.exists():
            info = json.loads(ij.read_text())
            info_p.write_text(json.dumps({k: info.get(k) for k in ("title", "track", "artist", "channel", "duration", "id")}))
            ij.unlink()
    return name


def stems(names, emit):
    todo = [n for n in names if not (dj.STEMS / n / "vocals.wav").exists()]
    if todo:
        emit({"type": "step", "text": "splitting stems (drums · bass · vocals · other) with Demucs"})
        subprocess.run([PY, "-m", "demucs", "-n", "htdemucs", "-d", "mps", "-o", str(ROOT / "stems")]
                       + [str(dj.TRACKS / f"{n}.wav") for n in todo], capture_output=True, check=True)


def analyze(name, emit):
    if not (dj.LIB / f"{name}.json").exists():
        emit({"type": "step", "text": f"finding the beat grid · {pretty(name)}"})
        dj.analyze_track(name)
    return dj.lib(name)


def pretty(name):
    p = dj.LIB / f"{name}.info.json"
    return clean_title(json.loads(p.read_text())) if p.exists() else name


def auto_cues(name):
    """Hook = the loud, vocal, drum-driven 4-bar phrase that repeats most (choruses repeat). Stab = strongest vocal onset in it."""
    import librosa
    t = dj.lib(name)
    L = {k: np.array(v, float) for k, v in t["levels"].items()}
    n = t["bars"]
    y, sr = librosa.load(str(dj.TRACKS / f"{name}.wav"), sr=22050, mono=True)
    bar_s = 4 * t["beat_sec"]
    chroma = []
    for b in range(n):
        a = int((t["first_downbeat"] + b * bar_s) * sr)
        seg = y[a:a + int(bar_s * sr)]
        c = librosa.feature.chroma_stft(y=seg, sr=sr, hop_length=2048).mean(axis=1) if len(seg) > 4096 else np.zeros(12)
        chroma.append(c / (np.linalg.norm(c) + 1e-9))
    chroma = np.array(chroma)
    cands = [b for b in range(4, max(5, n - 10), 4)]
    scores = {}
    for b in cands:
        blk = slice(b, min(n, b + 8))
        energy = L["mix"][blk].mean() + 0.8 * L["drums"][blk].mean() + 0.8 * L["vocals"][blk].mean() + 0.3 * L["bass"][blk].mean()
        rep = 0.0
        for c in cands:
            if abs(c - b) >= 8 and c + 4 <= n and b + 4 <= n:
                rep = max(rep, float(np.mean([chroma[b + k] @ chroma[c + k] for k in range(4)])))
        intro_pen = 3 if b < 8 else 0
        scores[b] = energy + 6 * rep - intro_pen
    ranked = sorted(scores, key=lambda b: -scores[b])
    hook = ranked[0]
    alt = next((b for b in ranked[1:] if abs(b - hook) >= 16), ranked[min(1, len(ranked) - 1)])
    # stab: strongest vocal onset on the 8th-note grid in the hook's first 2 bars (fallback: drums)
    beat = t["beat_sec"]
    stem = "vocals" if L["vocals"][hook:hook + 4].mean() >= 4 else "drums"
    v, _ = librosa.load(str(dj.STEMS / name / f"{stem}.wav"), sr=22050, mono=True)
    env = librosa.onset.onset_strength(y=v, sr=22050, hop_length=128)
    best, stab = -1, hook * 4.0
    for k in range(16):
        bt = hook * 4 + k * 0.5
        ts = t["first_downbeat"] + bt * beat
        i0 = int((ts - 0.06) * 22050 / 128)
        i1 = int((ts + 0.12) * 22050 / 128)
        if i1 >= len(env):
            break
        seg_rms = float(np.sqrt(np.mean(v[int(ts * 22050):int((ts + beat * 0.6) * 22050)] ** 2)))
        sc = env[i0:i1].max() * seg_rms
        if sc > best:
            best, stab = sc, bt + (np.argmax(env[i0:i1]) * 128 / 22050 - 0.06) / beat
    return {"hook": int(hook), "cues": [int(hook), int(alt)], "hook_len": 8, "stab": round(float(stab), 3),
            "stab_len": 0.75, "stab_src": stem}


def master_bpm(bpms):
    """Pick a shared tempo; allow half/double-time so a 70 and a 140 bpm track can meet."""
    ref = bpms[0]
    eff = [ref]
    for b in bpms[1:]:
        eff.append(min((b * f for f in (0.5, 1, 2)), key=lambda x: abs(math.log(x / ref))))
    m = math.exp(sum(math.log(e) for e in eff) / len(eff))
    return round(m * 2) / 2, [e / b for e, b in zip(eff, bpms)]


def build_crate(names, emit):
    bpms = [dj.lib(n)["bpm"] for n in names]
    mbpm, factors = master_bpm(bpms)
    meta = {}
    for n, f in zip(names, factors):
        emit({"type": "step", "text": f"finding the hook + a word to scratch · {pretty(n)}"})
        c = auto_cues(n)
        t = dj.lib(n)
        if abs(f - 1) > 1e-6:  # counted in half/double time: rescale bar/beat positions
            c = {**c, "hook": int(c["hook"] * f) // 4 * 4, "cues": [int(x * f) // 4 * 4 for x in c["cues"]], "stab": c["stab"] * f}
        meta[n] = {"title": pretty(n), **c, "bpm_eff": t["bpm"] * f, "time_factor": f,
                   "hook_desc": "the hook / chorus", "vibe": f"{t['bpm']:.0f} bpm, {t['key']}", "energy": "high", "word": "hook"}
        stretch = mbpm / (t["bpm"] * f) - 1
        emit({"type": "track", "name": n, "title": meta[n]["title"], "bpm": t["bpm"], "key": t["key"], "camelot": t["camelot"],
              "hook_bar": c["hook"], "stretch_pct": round(stretch * 100, 1)})
    return meta, mbpm


def run_job(job_id, a, b, brain_spec, bars, emit):
    from live import make_brain, perform
    with _lock:
        names = [fetch(a, emit), fetch(b, emit)]
        stems(names, emit)
        for n in names:
            analyze(n, emit)
        meta, bpm = build_crate(names, emit)
        if bars <= 12:  # short clip: one cue per song -> much less audio to stretch
            for m in meta.values():
                m["cues"] = m["cues"][:1]
        emit({"type": "step", "text": f"decks locked at {bpm:g} bpm · handing the decks to {brain_spec}"})
        brain = make_brain(brain_spec)
        name = f"mix_{job_id}"
        summ = perform(meta, names[0], bars, bpm, brain, name, on_event=emit, brain_label=label(brain_spec))
        emit({"type": "step", "text": "rendering the stage video"})
        subprocess.run([PY, str(ROOT / "stage.py"), str(ROOT / "out" / name)], capture_output=True, check=True)
        return summ


def label(spec):
    return {"jev": "jev", "random": "random"}.get(spec, spec.split("/")[-1])
