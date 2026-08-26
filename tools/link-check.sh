#!/bin/bash
# Does every link in the documentation actually go somewhere?
#
# A broken link is the cheapest possible way for an open project to look
# abandoned, and the easiest thing in the world to introduce: rename one file,
# move one doc, and a dozen references rot silently. This checks them.
#
#   bash tools/link-check.sh            # relative links only, offline, fast
#   bash tools/link-check.sh --external # also HEAD every http(s) link
#
# Relative targets are resolved against the file that contains them, `#anchors`
# are checked against the headings actually present in the target file, and a
# link into a directory is satisfied by the directory existing.
set -u
cd "$(dirname "$0")/.." || exit 2
EXTERNAL=0
[ "${1:-}" = "--external" ] && EXTERNAL=1

python3 - "$EXTERNAL" <<'PY'
import os, re, subprocess, sys, urllib.parse
external = sys.argv[1] == "1"
files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")

def anchors(path):
    """GitHub's heading -> anchor rule, closely enough to catch real mistakes."""
    out = set()
    try: text = open(path, encoding="utf-8", errors="replace").read()
    except OSError: return out
    for line in text.splitlines():
        m = re.match(r"\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m: continue
        h = m.group(1).lower()
        h = re.sub(r"[`*_~\[\]()]", "", h)
        h = re.sub(r"[^\w\s-]", "", h)
        # ONE hyphen per whitespace CHARACTER, not per run. GitHub does not
        # collapse them, and the difference is invisible until a heading
        # contains punctuation between two spaces:
        #   "Copyright and dual licensing — please read this part"
        # loses the em-dash and keeps both spaces, so the real anchor is
        # ...licensing--please... with two hyphens. Collapsing produced one,
        # and this checker reported a perfectly good link as broken -- a
        # false alarm being exactly as useless as a missed one.
        out.add(re.sub(r"\s", "-", h.strip()))
    return out

# ── CALIBRATE THE ANCHOR RULE BEFORE USING IT ────────────────────────────────
# Two inputs it must rank DIFFERENTLY, and one it must get exactly right. A
# slugger that is wrong in either direction turns this tool into noise.
_probe = {
    "Copyright and dual licensing \u2014 please read this part":
        "copyright-and-dual-licensing--please-read-this-part",
    "How a change gets accepted": "how-a-change-gets-accepted",
    "`code` in a heading (and parens)": "code-in-a-heading-and-parens",
}
def _slug(t):
    t = t.lower()
    t = re.sub(r"[`*_~\[\]()]", "", t)
    t = re.sub(r"[^\w\s-]", "", t)
    return re.sub(r"\s", "-", t.strip())
_wrong = {k: (_slug(k), v) for k, v in _probe.items() if _slug(k) != v}
if _wrong:
    for k, (got, want) in _wrong.items():
        print("  CALIBRATION FAILED: %r -> %r, GitHub makes %r" % (k, got, want))
    print("\nthe anchor rule is wrong; refusing to report on links")
    sys.exit(2)
print("anchor rule calibrated on %d known headings" % len(_probe))

bad, ext_urls, checked = [], set(), 0
for f in files:
    base = os.path.dirname(f)
    try: text = open(f, encoding="utf-8", errors="replace").read()
    except OSError: continue
    for raw in LINK.findall(text):
        checked += 1
        if raw.startswith(("http://", "https://")):
            ext_urls.add(raw); continue
        if raw.startswith(("mailto:", "#")):
            if raw.startswith("#") and raw[1:] and raw[1:] not in anchors(f):
                bad.append((f, raw, "no such heading in this file"))
            continue
        target, _, frag = raw.partition("#")
        target = urllib.parse.unquote(target)
        if not target: continue
        p = os.path.normpath(os.path.join(base, target))
        if not os.path.exists(p):
            bad.append((f, raw, "no such file")); continue
        if frag and p.endswith(".md") and frag not in anchors(p):
            bad.append((f, raw, "file exists, heading does not"))

print("checked %d links in %d markdown files" % (checked, len(files)))
for f, l, why in bad:
    print("  BROKEN  %s -> %s   (%s)" % (f, l, why))
print("  relative links broken: %d" % len(bad))

fails = len(bad)
if external:
    print("checking %d distinct external URLs..." % len(ext_urls))
    for u in sorted(ext_urls):
        r = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                            "-L", "--max-time", "20", "-A", "Mozilla/5.0", u],
                           capture_output=True, text=True)
        code = r.stdout.strip()
        # A HEAD-hostile host answering 403/405 is not a broken link; a 404 is.
        if code in ("404", "410", "000"):
            print("  BROKEN  %s   (HTTP %s)" % (u, code or "no response")); fails += 1
    print("  external links broken: %d" % (fails - len(bad)))
else:
    print("  (external links not checked -- pass --external for that)")

print()
print("LINK CHECK PASSED" if fails == 0 else "LINK CHECK FAILED (%d)" % fails)
sys.exit(0 if fails == 0 else 1)
PY
