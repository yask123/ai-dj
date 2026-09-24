import json, sys
import numpy as np
from live import perform, make_brain
meta = json.load(open(sys.argv[4] if len(sys.argv) > 4 else "demo_crate.json"))
bars, first, name = int(sys.argv[1]), sys.argv[2], sys.argv[3]
print(perform(meta, first, bars, float(sys.argv[5]) if len(sys.argv) > 5 else 101.0, make_brain("jev"), name, rng=np.random.default_rng(0), brain_label="jev"))
