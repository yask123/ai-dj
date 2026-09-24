"""Crate prep (the slow brain's job): hot cues from Whisper word timings, stab snapped to the vocal onset."""
import json
import librosa
import numpy as np
import dj

C = {  # track: title, hook bar, hook_len, stab word beat (from transcript), stab length (beats), hook description, vibe, energy
 "yeah":          ("Usher – Yeah!", 24, 12, 6.98, 0.9, "chorus: 'I said Yeah!'", "crunk-pop club anthem with a huge crowd shout", "very high"),
 "espresso":      ("Sabrina Carpenter – Espresso", 30, 8, 126.28, 1.0, "chorus: 'that's that me espresso'", "sassy bright summer pop singalong", "high"),
 "not_like_us":   ("Kendrick Lamar – Not Like Us", 31, 8, 126.10, 0.9, "hook chant: 'they not like us'", "stomping West Coast hype chant", "very high"),
 "get_low":       ("Lil Jon – Get Low", 98, 12, 392.66, 1.1, "'get low… to the window, to the wall'", "rowdy crunk party chant", "very high"),
 "jump_around":   ("House of Pain – Jump Around", 24, 12, 111.53, 0.6, "'jump around' + jump chant", "whole-crowd jumping chant, iconic squeal", "very high"),
 "hot_in_herre":  ("Nelly – Hot In Herre", 29, 8, 117.76, 1.1, "chorus: 'it's getting hot in here'", "playful 2000s party singalong", "high"),
 "crazy_in_love": ("Beyoncé – Crazy In Love", 40, 8, 161.75, 0.7, "chorus: 'got me looking so crazy right now'", "brassy iconic peak-time anthem", "very high"),
 "levitating":    ("Dua Lipa – Levitating", 16, 8, 79.05, 1.0, "chorus: 'I'm levitating'", "disco-pop groove, light and bright", "medium-high"),
}
out = {}
for name, (title, hook, hl, stab, sl, hd, vibe, en) in C.items():
    t = dj.lib(name)
    y, _ = librosa.load(f"stems/htdemucs/{name}/vocals.wav", sr=22050, mono=True)
    beat = t["beat_sec"]
    t0 = t["first_downbeat"] + stab * beat
    a, b = int((t0 - 0.3 * beat) * 22050), int((t0 + 0.25 * beat) * 22050)
    env = librosa.onset.onset_strength(y=y[a:b], sr=22050, hop_length=128)
    snap = a / 22050 + np.argmax(env) * 128 / 22050 - 0.01
    stab_beat = round((snap - t["first_downbeat"]) / beat, 3)
    out[name] = {"title": title, "hook": hook, "hook_len": hl, "stab": stab_beat, "stab_len": sl,
                 "hook_desc": hd, "vibe": vibe, "energy": en}
    print(f"{name:<14} hook bar {hook:>3} ({hl} bars)  stab {stab:.2f} -> {stab_beat:.2f} beats")
json.dump(out, open("crate.json", "w"), indent=1)
