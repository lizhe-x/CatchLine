# Regenerates ios/Catchline/Resources/{Localizable,InfoPlist}.xcstrings from keys.py + t*.py
import json, sys, importlib
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from keys import K
T = {}
for m in ('t1', 't2', 't3'):
    T.update(importlib.import_module(m).T)
P = importlib.import_module('t4').P
for lang in T:
    T[lang] = list(T[lang])
    T[lang][5] = P[lang][0]
    T[lang] += P[lang][1:]
errors = []
for lang, vals in T.items():
    if len(vals) != len(K): errors.append(f"{lang}: {len(vals)} vs {len(K)}"); continue
    for k, v in zip(K, vals):
        if k.count('%@') != v.count('%@'): errors.append(f"{lang}: {k!r} -> {v!r}")
if errors: print("\n".join(errors)); sys.exit(1)
import os
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Catchline', 'Resources') + '/'
info = json.load(open(root + 'InfoPlist.xcstrings'))  # mic prompt: unchanged
unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
strings = {k: {"localizations": {l: unit(T[l][i]) for l in sorted(T)}} for i, k in enumerate(K)}
for k in ['A+', 'A−', 'Catchline Pro', 'Mark Johnson, Acme Corp, W-2']: strings[k] = {"shouldTranslate": False}
json.dump({"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}, open(root + 'Localizable.xcstrings', 'w'), ensure_ascii=False, indent=2)
print(f"OK: {len(T)} languages x {len(K)} strings")
