#!/usr/bin/env python3
"""Turn a rendered set into a vertical reel: live CQT spectrum, deck lanes + playhead, move captions.

  reel.py sets/<name>.json [--dj "fable"]   ->  out/<name>.mp4   (run dj.py render first)
"""
import json
import subprocess
import sys
from pathlib import Path

import soundfile as sf

ROOT = Path(__file__).parent
OUT = ROOT / "out"
DIN = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
BG, ACCENT = "#0b0b0c", "#ff5a36"
PALETTE = ["#ff5a36", "#3fb6ff", "#c6ff3f", "#ffd23f", "#c77dff", "#3fffc6"]
W, H = 1080, 1920
LANES_Y, LANES_H, LANE_X0, LANE_W = 1560, 300, 60, 960


def lanes_png(S, total, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig = plt.figure(figsize=(W / 100, LANES_H / 100), dpi=100, facecolor=BG)
    ax = fig.add_axes([LANE_X0 / W, 0.12, LANE_W / W, 0.88], facecolor=BG)
    lane = lambda c: (c["track"], str(c.get("stems", "mix")))
    tracks = list(dict.fromkeys(c["track"] for c in S["clips"]))
    lanes = list(dict.fromkeys(lane(c) for c in S["clips"]))
    for c in S["clips"]:
        i = lanes.index(lane(c))
        ci = tracks.index(c["track"])
        stems = c.get("stems", "mix")
        label = c["track"].replace("_", " ").upper() + ("" if stems == "mix" else "  ·  " + "+".join(s[:3] for s in stems).upper())
        ax.barh(i, c["bars"], left=c["at"], height=0.62, color=PALETTE[ci % len(PALETTE)], alpha=0.85)
        ax.text(c["at"] + 0.3, i, label, va="center", fontsize=9, color=BG, fontweight="bold")
    for m in S.get("moves", []):
        ax.axvline(m["at"], color="white", lw=0.8, alpha=0.35)
    ax.set_xlim(0, total)
    ax.set_ylim(len(lanes) - 0.5, -0.5)
    ax.set_yticks([])
    ax.set_xticks(range(0, int(total) + 1, 4))
    ax.tick_params(colors="#777", labelsize=8, length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    fig.savefig(path, facecolor=BG)
    plt.close(fig)


def esc(t):
    return t.replace("\\", "\\\\").replace("'", "’").replace(":", "\\:").replace("%", "\\%")


def main():
    set_path = Path(sys.argv[1])
    dj = sys.argv[sys.argv.index("--dj") + 1] if "--dj" in sys.argv else set_path.stem.split("_")[0]
    S = json.loads(set_path.read_text())
    name = set_path.stem.replace(".reel", "")
    wav = OUT / f"{name}.wav"
    dur = sf.info(wav).duration
    bpm = S["bpm"]
    bar_s = 240 / bpm
    total_view = dur / bar_s
    lanes = OUT / f"{name}.lanes.png"
    lanes_png(S, total_view, lanes)

    tracks = list(dict.fromkeys(c["track"].replace("_", " ") for c in S["clips"]))
    sub = ("  ×  ".join(tracks) if len(tracks) <= 3 else f"{len(tracks)} songs quick-mix").upper() + f"   ·   {bpm:g} BPM"
    f = [
        f"color=c={BG}:s={W}x{H}:r=30:d={dur:.3f}[bg]",
        "[0:a]showcqt=s=1080x1000:fps=30:bar_g=2:sono_g=3:sono_v=bar_v*a_weighting(f):bar_v=13:axis=0:tc=0.2:count=4:csp=bt709,"
        "format=rgba,colorchannelmixer=aa=0.95[cqt]",
        "[bg][cqt]overlay=0:380[v1]",
        f"[1:v]format=rgba[ln]",
        f"[v1][ln]overlay=0:{LANES_Y}[v2]",
        f"color=c=white:s=3x{LANES_H - 36}:r=30[ph]",
        f"[v2][ph]overlay=x='{LANE_X0}+t/{dur:.3f}*{LANE_W}':y={LANES_Y}:eval=frame[v3]",
    ]
    dt = [
        f"drawtext=fontfile='{DIN}':text='AI DJ':fontsize=64:fontcolor={ACCENT}:x=60:y=110",
        f"drawtext=fontfile='{DIN}':text='{esc(dj.upper())}':fontsize=64:fontcolor=white:x=222:y=110",
        f"drawtext=fontfile='{DIN}':text='{esc(sub)}':fontsize=38:fontcolor=0x9a9a9a:x=60:y=200",
        f"drawtext=fontfile='{MONO}':text='BAR %{{eif\\:floor(t/{bar_s:.5f})\\:d}}.%{{eif\\:mod(floor(t/{bar_s/4:.5f})\\,4)+1\\:d}}':"
        f"fontsize=34:fontcolor=0x9a9a9a:x=w-text_w-60:y=122",
    ]
    groups = {}
    for m in S.get("moves", []):
        groups.setdefault(m["at"], []).append(m["text"].upper().replace("→", "›").replace("—", "-"))
    ats = sorted(groups)
    for i, at in enumerate(ats):
        a = at * bar_s
        b = min(a + 3.0, ats[i + 1] * bar_s if i + 1 < len(ats) else dur)
        lines = groups[at]
        y = 1470 - 60 * (len(lines) - 1)
        for j, line in enumerate(lines):
            fs = int(min(110 if j == 0 else 64, 960 / (0.43 * max(1, len(line)))))
            dt.append(
                f"drawtext=fontfile='{DIN}':text='{esc(line)}':fontsize={fs}:fontcolor={'white' if j == 0 else '0xbbbbbb'}:"
                f"x=(w-text_w)/2:y={y}-text_h/2:enable='between(t,{a:.3f},{b:.3f})':"
                f"alpha='min(1,(t-{a:.3f})/0.12)*min(1,({b:.3f}-t)/0.25)'")
            y += fs // 2 + 58
        dt.append(f"drawbox=x=0:y=0:w=iw:h=8:color={ACCENT}:t=fill:enable='between(t,{a:.3f},{a + 0.25:.3f})'")
    f.append("[v3]" + ",".join(dt) + ",format=yuv420p[v]")
    script = OUT / f"{name}.filter.txt"
    script.write_text(";\n".join(f))
    mp4 = OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-loop", "1", "-i", str(lanes),
                    "-filter_complex_script", str(script), "-map", "[v]", "-map", "0:a",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "256k",
                    "-t", f"{dur:.3f}", "-movflags", "+faststart", str(mp4)], check=True)
    print(mp4)


if __name__ == "__main__":
    main()
