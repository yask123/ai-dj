import json, sys, mlx_whisper
from pathlib import Path
import dj
out = Path("library")
for name in sys.argv[1:]:
    r = mlx_whisper.transcribe(f"stems/htdemucs/{name}/vocals.wav", path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
                               word_timestamps=True, language="en", condition_on_previous_text=False)
    t = dj.lib(name); beat = t["beat_sec"]; fd = t["first_downbeat"]
    words = [{"w": w["word"].strip(), "t": round(w["start"], 3), "beat": round((w["start"] - fd) / beat, 2)}
             for s in r["segments"] for w in s.get("words", [])]
    (out / f"{name}.words.json").write_text(json.dumps(words))
    # print lyric lines per bar
    lines = {}
    for w in words:
        b = int(w["beat"] // 4)
        lines.setdefault(b, []).append(w["w"])
    print(f"\n=== {name}")
    for b in sorted(lines):
        print(f"{b:>4}: {' '.join(lines[b])}")
