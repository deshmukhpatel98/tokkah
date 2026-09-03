#!/bin/bash
# ── A DUPLICATE KEY IN A DICTIONARY LITERAL ───────────────────────────────────
#
# Swift traps on it (`Dictionary.init(dictionaryLiteral:)` precondition). Built
# -Ounchecked, as this app was from its first commit, the check is compiled out
# and the later entry silently wins. Twice now that has cost something real:
# once a measured 8 ms fix (duplicate-key-eats-shipped-fix), and once the
# canceller's `aec_on` beat field, overwritten on every beat by a stale second
# definition -- found only when the first -O build trapped on its first live call.
#
# This walks every `[ "key": ... ]` literal in Sources/ and refuses duplicates.
# Nested literals are walked separately, so `["a": ["x": 1], "b": ["x": 2]]` is
# fine. Exit 1 on any hit. Cheap enough to run before every release.
set -u
cd "$(dirname "$0")/.." || exit 2
python3 - "$@" <<'PY'
import re, glob, sys
bad = 0
def literals(s):
    """Yield (start, text) for every top-level-or-nested dictionary literal."""
    for m in re.finditer(r'\[\s*"[A-Za-z_0-9]+"\s*:', s):
        start = m.start(); depth = 0; j = start
        while j < len(s):
            c = s[j]
            if c == '[': depth += 1
            elif c == ']':
                depth -= 1
                if depth == 0: break
            j += 1
        yield start, s[start:j+1]
def own_keys(lit):
    """Keys at THIS literal's depth only (nested literals are not ours)."""
    keys = []; depth = 0; i = 0
    while i < len(lit):
        c = lit[i]
        if c == '[': depth += 1
        elif c == ']': depth -= 1
        elif c == '"' and depth == 1:
            m = re.match(r'"([A-Za-z_0-9]+)"\s*:', lit[i:])
            if m and re.search(r'[\[,]\s*$', lit[:i]): keys.append(m.group(1))
            # skip the string
            j = lit.find('"', i + 1)
            i = j if j > 0 else i
        i += 1
    return keys
for f in sorted(glob.glob('Sources/tk/*.swift')):
    s = open(f).read()
    for start, lit in literals(s):
        keys = own_keys(lit)
        dups = sorted({k for k in keys if keys.count(k) > 1})
        if dups:
            bad += 1
            print(f"  DUPLICATE {f}:{s[:start].count(chr(10))+1} {dups}")
print("dupkey-check: " + ("PASS -- no duplicate keys in any dictionary literal" if not bad else f"FAIL -- {bad} literal(s)"))
sys.exit(1 if bad else 0)
PY
