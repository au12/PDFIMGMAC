#!/usr/bin/env python3
"""Check Pluck's output folder against tests/expected.json.

usage: verify.py OUTPUT_DIR [--keep-jpeg]
"""
import json, os, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
out_dir = sys.argv[1]
keep_jpeg = "--keep-jpeg" in sys.argv
expected = json.load(open(os.path.join(HERE, "expected.json")))

files = sorted(os.listdir(out_dir))
print("produced:", files)
fails = []
want_names = []
for e in expected:
    ext = "jpg" if (keep_jpeg and e["jpeg"]) else "png"
    name = f"{e['file']}.{ext}"
    want_names.append(name)
    path = os.path.join(out_dir, name)
    if not os.path.exists(path):
        fails.append(f"missing {name}"); continue
    im = Image.open(path).convert("RGBA")
    if im.size != (e["w"], e["h"]):
        fails.append(f"{name}: size {im.size} != {(e['w'], e['h'])}")
    for x, y, want, tol in e["checks"]:
        got = im.getpixel((x, y))
        for ch, (g, w) in enumerate(zip(got, want)):
            if w is None:
                continue
            if isinstance(w, str):
                ok = g < int(w[1:]) if w[0] == "<" else g > int(w[1:])
            else:
                ok = abs(g - w) <= tol
            if not ok:
                fails.append(f"{name} @({x},{y}) ch{ch}: got {got}, want {want} ±{tol}")
                break
extra = set(files) - set(want_names)
if extra:
    fails.append(f"unexpected files: {sorted(extra)}")

if fails:
    print("FAIL"); [print("  -", f) for f in fails]; sys.exit(1)
print(f"OK: {len(expected)} images verified")
