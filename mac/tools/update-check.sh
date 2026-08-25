#!/bin/bash
# ── THE ONE MECHANISM THAT CAN BRICK A MAC 15 KM AWAY ────────────────────────
#
# Every other rig in this directory tests something a person can recover from by
# quitting and reopening. This one tests the thing they cannot: an updater that
# installs a bad payload, or refuses a good one, or accepts a payload nobody
# signed, reaches every installed copy at once and there is no way back in. Until
# now its only proof was a production log -- `TK_UPDATE_BASE`, `TK_UPDATE_POLL`
# and `TK_UPDATE_GRACE` were documented in LAUNCH.md and driven by no script at
# all, so the security gate at the centre of it had never been shown to say no.
#
# So this stands up a fake update server on 127.0.0.1, builds a REAL second
# version of tk with a bumped VERSION, wraps both in real .app bundles, and runs
# the actual product against it. Nothing is stubbed: the manifests are signed with
# the release key, the payloads are the tarballs release.sh would cut, and the
# code under test is the shipping code path down to the RENAME_SWAP.
#
# ── EVERY CLAIM HAS AN ARM THAT RANKS THE OTHER WAY ─────────────────────────
#
# This project has been burned repeatedly by rigs that were blind to the defect
# they existed to catch, and by instruments that return the same value for "no"
# and "cannot see" (`blind-instruments-report-negatives`). A refusal arm proves
# nothing on its own -- a build with the network unplugged refuses everything and
# passes. So each claim below is paired:
#
#   installs a newer version        <->  a not-newer version does nothing
#   refuses a tampered manifest     <->  the untampered one installs
#   refuses a tampered payload      <->  the untampered one installs
#   --watch updates by itself       <->  --watch --no-update does not
#   TK_UPDATE_GRACE=2 fetches at 2s <->  TK_UPDATE_GRACE=8 fetches at 8s
#   a writable install updates once <->  a read-only one re-downloads forever
#
# and the negative arms are asserted on a POSITIVE instrument wherever possible:
# not "no error appeared" but "the server was never asked for the payload", and
# "the binary on disk still reports the old version".
#
# ── AND IT NEVER GOES NEAR THE REAL INSTALL ─────────────────────────────────
#
# /Applications/Kin.app, ~/Library/Application Support/Kin, the user's
# LaunchAgent and room.tokkah.com are all untouched:
#   TK_UPDATE_BASE   points at this script's own server, never the real one
#   TK_KIN_DIR       an identity dir inside the scratch directory
#   TK_KIN_BASE      a dead port, so the doorbell cannot reach the real server
#   TMPDIR           inside the scratch dir, so `stage()` cannot litter or collide
#                    with a real update being staged by the user's own copy
#   --no-relocate    the copy under test must never install itself to /Applications
#   a different CFBundleIdentifier, and no URL schemes, so LaunchServices never
#                    resolves `kin://` or a Finder double-click to a temp bundle
#                    (`helper-sharing-bundle-id`)
#
# Usage:  mac/tools/update-check.sh          (KEEP=1 to leave the scratch dir)
set -u
# Ring and status windows do not throw themselves in front of whatever the person
# at this Mac is doing, but the copies here re-exec and one of them owns a menu
# bar item -- so this is belt and braces.
export TK_NO_RAISE=1

# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# Never `pkill -f`: it takes a REGEX, and in a path like `.build/debug/tk` every
# `.` matches any character, so it has reaped other agents' processes in other
# checkouts. PIDs only.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
# `wait "$p"`, NOT the bare `wait` the other rigs in this directory use. A bare
# wait waits for EVERY child, and this script has one child that never exits on
# purpose -- the update server below. The first version hung there for ten
# minutes with nothing on stdout.
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""; }
# ── THE SERVER IS NOT ONE OF THE THINGS `reap` REAPS ────────────────────────
#
# It was, once, because `spawn` is the obvious way to start it -- and the first
# `reap` after the first arm killed the instrument. Every arm from then on found
# a dead port, `Update.get` returned nil with no message, and the whole run read
# as "the poller never ran": eleven arms of clean-looking evidence produced by a
# test that had shot its own measuring device. Its own pid, killed only at the end.
SRV=""
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/update-check.$$"
# Where failing logs get copied to, captured BEFORE TMPDIR is redirected below --
# otherwise the failure logs would be written into the directory the trap is
# about to delete, which is the one run where you actually want them.
OUT="${SCRATCH:-${TMPDIR:-/tmp}}"
mkdir -p "$SP/tmp" "$SP/srv/dl" "$SP/id"
# The read-only arm below strips the write bit from a whole bundle on purpose, so
# the cleanup has to put it back before it can delete anything.
trap 'reap; kill -9 $SRV 2>/dev/null; chmod -R u+w "$SP" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$SP"; true' EXIT

# ── `stage()` UNPACKS INTO $TMPDIR, AND $TMPDIR IS SHARED ───────────────────
#
# `FileManager.temporaryDirectory` is the per-user /var/folders directory, which
# the user's REAL Kin also stages into. Two copies staging the same version share
# one path and the first thing `stage()` does is delete it. Pointing the children
# at a scratch TMPDIR keeps this rig out of that, and keeps the collision the race
# arm is looking for confined to the two processes this script started.
export TMPDIR="$SP/tmp"

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
cant() { echo "UPDATE CHECK COULD NOT RUN -- $1"; exit 2; }

[ -x "$TK" ] || cant "no tk at $TK -- swift build --package-path mac first"
# The rig has to produce manifests the compiled-in public key accepts, and there
# is deliberately no override for that key: "a security control with a bypass is
# decoration". So this needs the real release signing key, and on a machine
# without it the honest answer is that the test cannot run -- not a pass.
SIGN="$HERE/sign"
[ -x "$SIGN" ] || SIGN=""
KEYFILE="$HOME/.config/tokkah/mac-update-ed25519.key"
[ -f "$KEYFILE" ] || cant "no signing key at $KEYFILE -- this rig signs its own manifests with the real key because Update.publicKeyHex has no override"
sign() { # <file> -> base64 signature on stdout
  if [ -n "$SIGN" ]; then "$SIGN" "$1"; else swift "$HERE/sign.swift" "$1"; fi
}
command -v python3 >/dev/null || cant "python3 is needed for the fake update server"
if nc -z 127.0.0.1 8097 2>/dev/null; then cant "something is already listening on 127.0.0.1:8097"; fi

OLD="$(grep -o 'let VERSION = "[^"]*"' "$HERE/../Sources/tk/main.swift" | sed 's/.*"\(.*\)"/\1/')"
[ -n "$OLD" ] || cant "cannot read VERSION out of Sources/tk/main.swift"
NEW="$(echo "$OLD" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')"
OLDER="$(echo "$OLD" | awk -F. '{printf "%d.%d.%d", $1, ($2>0?$2-1:0), 0}')"
echo "== versions: installed $OLD, release $NEW, stale $OLDER =="

# ── A REAL SECOND BUILD, NOT A RELABELLED FIRST ONE ─────────────────────────
#
# "The process comes back running the new version" is only provable if the new
# version is a different program. A rig that serves the same binary under a
# higher number proves the download and nothing after it -- and worse, the
# re-exec'd image would report the OLD version, see the manifest as newer again,
# and update in a loop, which is a defect this rig would then be unable to see.
# So the source is copied, VERSION is bumped, and it is compiled. About 25 s.
echo "== building $NEW =="
mkdir -p "$SP/src"
cp "$HERE/../Package.swift" "$SP/src/"
cp -R "$HERE/../Sources" "$SP/src/"
sed -i '' "s/let VERSION = \"$OLD\"/let VERSION = \"$NEW\"/" "$SP/src/Sources/tk/main.swift"
grep -q "let VERSION = \"$NEW\"" "$SP/src/Sources/tk/main.swift" \
  || cant "the VERSION bump in the scratch copy matched nothing"
swift build --package-path "$SP/src" --product tk > "$SP/build.log" 2>&1 \
  || { sed -n '1,25p' "$SP/build.log"; cant "the $NEW build failed -- see $SP/build.log"; }
NEWBIN="$SP/src/.build/debug/tk"
[ -x "$NEWBIN" ] || cant "no binary at $NEWBIN after the build"
got="$("$NEWBIN" --version)"
[ "$got" = "$NEW" ] || cant "the freshly built binary reports $got, not $NEW"
[ "$("$TK" --version)" = "$OLD" ] || cant "the repo binary reports $("$TK" --version), not $OLD"

# ── A REAL BUNDLE, BECAUSE THE PRODUCTION PATH IS THE BUNDLE PATH ───────────
#
# `swapBundle` refuses anything not under `/Contents/MacOS/` and falls through to
# the legacy binary-only path, which is NOT what any current install takes. A rig
# that ran the bare binary would test the branch nobody is on.
#
# The identifier is changed and the URL schemes are dropped on purpose. A bundle
# carrying `com.tokkah.tk` and `kin://` in a temp directory is one LaunchServices
# scan away from swallowing the user's real invite links and their Dock clicks --
# which is exactly how a helper sharing a bundle id made Kin unlaunchable from
# Finder once already.
mkbundle() { # <version> <binary> <app-dir>
  local ver="$1" bin="$2" app="$3"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  python3 - "$HERE/../bundle/Info.plist" "$app/Contents/Info.plist" "$ver" <<'PY'
import plistlib, sys
src, dst, ver = sys.argv[1], sys.argv[2], sys.argv[3]
d = plistlib.load(open(src, "rb"))
d["CFBundleIdentifier"] = "com.tokkah.tk.updatecheck"
d["CFBundleName"] = d["CFBundleDisplayName"] = "KinUpdateCheck"
d.pop("CFBundleURLTypes", None)
d["CFBundleShortVersionString"] = d["CFBundleVersion"] = ver
# ── APP TRANSPORT SECURITY IS A PROPERTY OF THE BUNDLE, NOT OF THE CODE ─────
#
# The first run of this rig fetched NOTHING and every log was empty. A bare
# binary has no Info.plist so ATS is not enforced on it; the moment the same
# binary is inside a bundle, `http://127.0.0.1` is refused by URLSession -- and
# `Update.get` returns nil on any failure with no message at all, so the only
# evidence was silence. Production talks https to room.tokkah.com and never meets
# this, so the exception lives HERE, in the rig's bundle, and not in the product's
# plist: a test must not move the thing it is testing.
d["NSAppTransportSecurity"] = {
    "NSAllowsLocalNetworking": True,
    "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}},
}
plistlib.dump(d, open(dst, "wb"))
PY
  cp "$bin" "$app/Contents/MacOS/Tokkah"
  chmod +x "$app/Contents/MacOS/Tokkah"
  printf 'APPL????' > "$app/Contents/PkgInfo"
}

# ── THE PAYLOAD release.sh WOULD CUT ────────────────────────────────────────
#
# `tk` + `bundle/` is the legacy payload every updater at 0.45.0 or older needs;
# `Kin.app/` is what a current updater takes. Both are in the archive because both
# are in the real one, and the difference between them is the subject of the
# install.sh finding at the bottom of this file.
echo "== packaging =="
mkbundle "$NEW" "$NEWBIN" "$SP/pkg/Kin.app"
# ── A PAYLOAD WITH ENOUGH FILES IN IT TO SEE A HALF-COPY ────────────────────
#
# Both of the collisions the race arm hunts are per-FILE work -- `tar -xzf` into
# a staging directory and `ditto` into `.Kin.app.new` -- so on a four-file bundle
# they are over before they can overlap, and the arm reports "clean" for a build
# that corrupts installs. This padding is what turns a race that exists into a
# race that is observable: with it, the pre-fix code installed a bundle missing
# 3-9% of its files in four runs out of six.
#
# It is the tail of the bundle that goes missing, and in a REAL bundle the tail
# is `_CodeSignature/` -- which sorts last -- so the file this models losing is
# the signature that every camera and microphone grant is pinned to.
python3 - "$SP/pkg/Kin.app/Contents/Resources" <<'PY'
import os, sys
d = sys.argv[1] + "/pad"
os.makedirs(d, exist_ok=True)
blob = b"x" * 1024
for i in range(6000):
    open("%s/f%05d.bin" % (d, i), "wb").write(blob)
PY
mkdir -p "$SP/pkg/bundle"
cp "$HERE/../bundle/Info.plist" "$SP/pkg/bundle/Info.plist"
[ -f "$HERE/../bundle/AppIcon.icns" ] && cp "$HERE/../bundle/AppIcon.icns" "$SP/pkg/bundle/"
cp "$NEWBIN" "$SP/pkg/tk"
TARNAME="tk-$NEW.tar.gz"
tar -czf "$SP/srv/dl/$TARNAME" -C "$SP/pkg" tk bundle Kin.app
GOODSHA="$(shasum -a 256 "$SP/srv/dl/$TARNAME" | awk '{print $1}')"
GOODSIZE="$(stat -f%z "$SP/srv/dl/$TARNAME")"
PAYFILES="$(cd "$SP/pkg/Kin.app" && find . -type f | sort | wc -l | tr -d ' ')"
# One byte, in the middle, so the archive is still an archive and the hash is the
# only thing that catches it.
cp "$SP/srv/dl/$TARNAME" "$SP/srv/dl/bad.tar.gz"
python3 - "$SP/srv/dl/bad.tar.gz" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
    f.seek(len(f.read()) // 2); f.seek(-1, 1)
    b = f.read(1); f.seek(-1, 1); f.write(bytes([b[0] ^ 0x01]))
PY
BADSHA="$(shasum -a 256 "$SP/srv/dl/bad.tar.gz" | awk '{print $1}')"
echo "  $TARNAME $GOODSIZE bytes, $PAYFILES files in the bundle, sha256 ${GOODSHA:0:16}…  (corrupt copy ${BADSHA:0:16}…)"

mkman() { # <arm> <version> <url> <sha> [notes]
  mkdir -p "$SP/srv/$1"
  printf '{"version":"%s","url":"%s","sha256":"%s","size":%s,"appName":"Kin","notes":"%s"}' \
    "$2" "$3" "$4" "$GOODSIZE" "${5:-update-check rig}" > "$SP/srv/$1/manifest.json"
  sign "$SP/srv/$1/manifest.json" > "$SP/srv/$1/manifest.json.sig"
}
DL="http://127.0.0.1:8097/dl/$TARNAME"

# The arms. Each gets its own directory under the server root so its manifest,
# its tampering and its ENTRY IN THE ACCESS LOG belong to it alone -- the log is
# how "this process asked for an update" is proved without believing anything the
# process says about itself.
mkman ok      "$NEW"   "$DL?arm=ok"      "$GOODSHA"
mkman older   "$OLDER" "$DL?arm=older"   "$GOODSHA"
mkman body    "$NEW"   "$DL?arm=body"    "$GOODSHA"
mkman sig     "$NEW"   "$DL?arm=sig"     "$GOODSHA"
mkman hash    "$NEW"   "$DL?arm=hash"    "0000000000000000000000000000000000000000000000000000000000000000"
mkman tgz     "$NEW"   "http://127.0.0.1:8097/dl/bad.tar.gz?arm=tgz" "$GOODSHA"
mkman watch   "$NEW"   "$DL?arm=watch"   "$GOODSHA"
mkman nowatch "$NEW"   "$DL?arm=nowatch" "$GOODSHA"
mkman ro      "$NEW"   "$DL?arm=ro"      "$GOODSHA"
mkman race    "$NEW"   "$DL?arm=race"    "$GOODSHA"
mkman cadA    "$OLDER" "$DL?arm=cadA"    "$GOODSHA"
mkman cadB    "$OLDER" "$DL?arm=cadB"    "$GOODSHA"
mkman probe   "$OLDER" "$DL?arm=probe"   "$GOODSHA"

# ── THE THREE WAYS TO LIE TO AN UPDATER ─────────────────────────────────────
#
# 1. body -- edit the manifest and keep the signature. This is the attack: a
#    compromised bucket or a wrong DNS answer serves a manifest pointing at
#    someone else's payload. One byte, same length, so nothing but the signature
#    can catch it.
# 2. sig  -- flip a byte in the signature itself. Still valid base64, so it gets
#    all the way to the Ed25519 check rather than falling out of the decoder.
#    (A signature that is not even base64 is refused SILENTLY, with no line on
#    stderr at all -- checked, and noted, because it is the same verdict for a
#    corrupted file as for an attack.)
# 3. hash -- a correctly signed manifest that names a sha256 the payload does not
#    have, plus a payload whose byte was flipped after signing. The signature and
#    the hash are two independent gates and a rig that only ever breaks one
#    cannot tell you the other exists.
python3 - "$SP/srv/body/manifest.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
assert "update-check rig" in s
open(p, "w").write(s.replace("update-check rig", "update-check RIG"))   # one byte
PY
python3 - "$SP/srv/sig/manifest.json.sig" <<'PY'
import base64, sys
p = sys.argv[1]; raw = bytearray(base64.b64decode(open(p).read().strip()))
raw[0] ^= 0x01
open(p, "w").write(base64.b64encode(bytes(raw)).decode() + "\n")
PY

# ── The fake update server ──────────────────────────────────────────────────
#
# Threaded, not `python3 -m http.server`: the race arm has two processes
# downloading at once and a single-threaded server would serialise them, which
# narrows the very window the arm exists to open.
cat > "$SP/serve.py" <<'PY'
import functools, http.server, socketserver, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
S(("127.0.0.1", 8097), h).serve_forever()
PY
python3 "$SP/serve.py" "$SP/srv" > "$SP/srv.log" 2>&1 &
SRV=$!
# Off the job table, so bash does not print "Killed: 9" under the verdicts when
# the trap ends it. It is still killed by pid.
disown $SRV 2>/dev/null || true
perl -e 'select undef,undef,undef,1'
# Its own file, on a path no arm uses. Curling an arm's manifest would put a line
# in the access log that the verdicts then count as the app having polled -- the
# rig proving its own claim.
printf 'up\n' > "$SP/srv/ping"
curl -fsS "http://127.0.0.1:8097/ping" > /dev/null 2>&1 \
  || cant "the fake update server never came up -- see $SP/srv.log"

export TK_KIN_DIR="$SP/id"
# The doorbell must not reach the real server: nothing is listening on 8098, so
# every identity poll is a refused connection and this rig cannot claim a handle,
# squat a name, or read the mailbox of the person using this Mac.
export TK_KIN_BASE="http://127.0.0.1:8098"
export TK_NO_IDENTITY=1
# The watcher's front-door delegate is off. With a different bundle id it could
# not have caught a real launch anyway, but a resident that answers reopen events
# for a bundle in a temp directory is not a thing to leave to reasoning.
export TK_WATCH_NO_DELEGATE=1
export TK_WATCH_LABEL="com.tokkah.tk.updatecheck"

ARGS="--video off --mute --no-telemetry --no-relocate --no-rings --no-subtitles"
# ── A LAUNCH THAT REACHES THE UPDATER AND NEVER OPENS A DEVICE ──────────────
#
# `--incoming <somebody-not-in-contacts>` is the ring-preview path: the app runs
# its whole startup, including `Update.startPolling`, and then stops one line
# above `audio.start()` -- "no green light, nothing on the wire, nothing played".
# That matters here for a reason that has nothing to do with ringing: a person is
# using this Mac, and a fresh bundle identifier asking for the microphone would
# put a system dialog in front of them.
RING="--incoming astranger"

# Grace and poll are POSITIONAL, not `GRACE=2 run ...`. A variable assignment in
# front of a shell FUNCTION persists after the call in some bash builds and is
# restored in others, so the cadence arms would have silently leaked their
# settings into every later arm on one machine and not on another --
# `silent-no-op-flags` with the no-op depending on the shell.
run() { # <arm> <install-dir> <seconds> <grace> <poll> <args...>
  local arm="$1" dir="$2" secs="$3" g="$4" p="$5"; shift 5
  spawn env TK_UPDATE_BASE="http://127.0.0.1:8097/$arm" \
            TK_UPDATE_POLL="$p" TK_UPDATE_GRACE="$g" \
            "$dir/Kin.app/Contents/MacOS/Tokkah" "$@" > "$SP/$arm.log" 2>&1
  perl -e "select undef,undef,undef,$secs"
  reap
}
ver_on_disk() { "$1/Kin.app/Contents/MacOS/Tokkah" --version 2>/dev/null || echo "WILL-NOT-RUN"; }
plist_ver() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
                "$1/Kin.app/Contents/Info.plist" 2>/dev/null || echo "?"; }
# `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so the obvious
# `$(grep -c ... || echo 0)` yields the two-line string "0\n0" and every numeric
# comparison against it is a shell error, not a verdict. Swallow the status, keep
# the count.
hits() { local n; n="$(grep -c "GET /$1" "$SP/srv.log" 2>/dev/null || true)"; echo "${n:-0}"; }
lines() { local n; n="$(grep -c "$2" "$1" 2>/dev/null || true)"; echo "${n:-0}"; }
first_hit() { # <path fragment> <epoch at launch> -> whole seconds, or -1
  python3 - "$SP/srv.log" "$1" "$2" <<'PY'
import sys, time
log, frag, t0 = sys.argv[1], sys.argv[2], float(sys.argv[3])
for line in open(log):
    if frag not in line: continue
    try:
        e = time.mktime(time.strptime(line.split("[", 1)[1].split("]", 1)[0], "%d/%b/%Y %H:%M:%S"))
    except Exception:
        continue
    print(int(round(e - t0))); break
else:
    print(-1)
PY
}

# ── GUARD: DOES A BUNDLE START, ASK FOR NOTHING, AND REACH THIS SERVER? ─────
#
# Six seconds against a manifest that is deliberately STALE, so it proves the
# transport without installing anything. Three separate ways this rig can be
# worthless, all of them silent:
#
#   the bundle does not launch                 -- every arm is empty
#   macOS treats it as its own TCC identity    -- a microphone dialog appears in
#                                                 front of whoever is at this Mac
#   ATS or anything else eats the fetch        -- `Update.get` returns nil with no
#                                                 message, so EVERY negative arm
#                                                 below passes for the wrong
#                                                 reason and the whole run reads
#                                                 as a clean pass
#
# The third one actually happened on the first run of this script. That is
# `blind-instruments-report-negatives` exactly: an instrument that cannot see the
# event returns the same value as a real negative. So it is a COULD NOT RUN, and
# it is checked before a single verdict is printed.
for d in probe ok older body sig hash tgz watch nowatch ro race cadA cadB; do
  mkdir -p "$SP/$d"; mkbundle "$OLD" "$TK" "$SP/$d/Kin.app"
done
run probe "$SP/probe" 6 1 2 $ARGS --room "upd${$}pr" --listen 8098 --peer 127.0.0.1:8097 $RING
grep -q "^tk $OLD " "$SP/probe.log" \
  || { sed -n '1,12p' "$SP/probe.log"; cant "the bundled copy never started"; }
! grep -q "mic: asking for permission" "$SP/probe.log" \
  || cant "this bundle is its own TCC identity and macOS would prompt for the microphone -- refusing to run twelve more of these at somebody"
grep -q "ring: waiting to be answered -- no microphone, no camera" "$SP/probe.log" \
  || cant "the no-device launch path did not run; this rig would open the microphone"
[ "$(hits "probe/manifest.json HTTP")" -gt 0 ] \
  || cant "the bundled copy never reached the fake update server -- with the transport dead every refusal arm below would pass vacuously"

echo "== running the arms =="

# ── 1. A NEWER SIGNED VERSION LANDS, AND THE PROCESS COMES BACK AS IT ───────
run ok "$SP/ok" 20 2 3 $ARGS --room "upd${$}ok" --listen 8098 --peer 127.0.0.1:8097 $RING

# ── 3. AND A VERSION THAT IS NOT NEWER DOES NOTHING ─────────────────────────
# The arm that makes arm 1 mean something. Same server, same signature, same
# poller -- only the number is lower.
run older "$SP/older" 10 2 3 $ARGS --room "upd${$}old" --listen 8098 --peer 127.0.0.1:8097 $RING

# ── 2. THE GATE THAT MUST NEVER WEAKEN ──────────────────────────────────────
for a in body sig hash tgz; do
  run "$a" "$SP/$a" 10 2 3 $ARGS --room "upd${$}$a" --listen 8098 --peer 127.0.0.1:8097 $RING
done

# ── 4. THE WATCHER UPDATES A MAC WITH NO APP OPEN ───────────────────────────
#
# `Update.startPolling` sits ~350 lines below `Watch.run`, which returns `Never`.
# So until this release the one process that lives from login to logout had never
# once asked whether a newer Kin existed -- guard by unreachability, again. The
# whole point of this arm is that it must FAIL against the previous code, and the
# instrument that makes that true is the access log: a watcher that never polls
# leaves zero lines under /watch/, which is a different observation from "it
# polled and declined".
run watch "$SP/watch" 28 2 3 --watch --no-telemetry --no-rings
# The opposite arm. `--no-update` is documented as being for bisecting a
# regression, and it has to keep meaning that here too.
run nowatch "$SP/nowatch" 12 2 3 --watch --no-update --no-telemetry --no-rings

# ── 5. THE RIG OVERRIDES ACTUALLY OVERRIDE ──────────────────────────────────
#
# A rig override that silently does nothing has produced false results in this
# repo before, so these are measured against the SERVER's clock rather than the
# app's own words. Both arms serve a stale manifest, so nothing installs and the
# poller keeps ticking for the whole window. If TK_UPDATE_GRACE were ignored both
# would first fetch at the built-in 10 s and the two arms would be identical --
# which is exactly the failure this pair is shaped to catch.
CA0=$(date +%s); run cadA "$SP/cadA" 15 2 2 $ARGS --room "upd${$}ca" --listen 8098 --peer 127.0.0.1:8097 $RING
CB0=$(date +%s); run cadB "$SP/cadB" 15 8 8 $ARGS --room "upd${$}cb" --listen 8098 --peer 127.0.0.1:8097 $RING

# ── 6. AN INSTALL IT CANNOT WRITE TO ────────────────────────────────────────
#
# /Applications is drwxrwxr-x root:admin. A standard, non-admin account on a Mac
# where an admin installed Kin can write neither the staging directory beside the
# bundle nor anything inside it -- so it can never update, for as long as it owns
# that Mac. This arm is that account: the bundle and its parent lose the write
# bit and the updater is asked to install anyway.
chmod -R a-w "$SP/ro/Kin.app"; chmod a-w "$SP/ro"
run ro "$SP/ro" 14 2 3 $ARGS --room "upd${$}ro" --listen 8098 --peer 127.0.0.1:8097 $RING
chmod u+w "$SP/ro"; chmod -R u+w "$SP/ro/Kin.app"

# ── 7. TWO UPDATERS AT ONCE ─────────────────────────────────────────────────
#
# The change that started this rig means the watcher and the foreground app can
# now both decide to install, from one bundle, at the same moment. RENAME_SWAP is
# atomic; the `ditto` that precedes it is not, and neither is the `tar -xzf` in
# `stage()`. Both used to write to a path derived only from the VERSION, so two
# updaters shared it and deleted it under each other -- measured on this machine
# as an installed bundle missing 3-9% of its files, four runs in six, with no
# error printed by either process. Both are now per-process; this arm is what
# holds that. Started together, same grace, so they tick together.
spawn env TK_UPDATE_BASE="http://127.0.0.1:8097/race" TK_UPDATE_POLL=3 TK_UPDATE_GRACE=3 \
      "$SP/race/Kin.app/Contents/MacOS/Tokkah" --watch --no-telemetry --no-rings \
      > "$SP/race-w.log" 2>&1
spawn env TK_UPDATE_BASE="http://127.0.0.1:8097/race" TK_UPDATE_POLL=3 TK_UPDATE_GRACE=3 \
      "$SP/race/Kin.app/Contents/MacOS/Tokkah" $ARGS --room "upd${$}rc" --listen 8098 \
      --peer 127.0.0.1:8097 $RING > "$SP/race-f.log" 2>&1
perl -e 'select undef,undef,undef,22'
reap

echo
echo "== verdicts =="

# ── 1. A NEWER SIGNED VERSION IS PICKED UP, STAGED, VERIFIED AND INSTALLED ──
echo "1. a newer signed version lands"
[ "$(hits "ok/manifest.json HTTP")" -gt 0 ] \
  && say "OK" "the poller asked this server for a manifest ($(hits "ok/manifest.json HTTP") times)" \
  || say "FAIL" "nothing ever fetched /ok/manifest.json -- the poller never ran"
grep -q "update: $NEW staged and verified" "$SP/ok.log" \
  && say "OK" "$NEW downloaded, hash checked, and launch-probed before anything moved" \
  || say "FAIL" "$NEW was never staged: $(grep -o 'update: .*' "$SP/ok.log" | tail -1)"
grep -q "update: installed $NEW -- restarting" "$SP/ok.log" \
  && say "OK" "and installed" \
  || say "FAIL" "it staged $NEW and never installed it"
# The claim that matters: not "it printed installed" but "the program on disk is
# a different program now". Asked of the binary itself, not of the log.
[ "$(ver_on_disk "$SP/ok")" = "$NEW" ] \
  && say "OK" "the binary in the bundle now reports $NEW" \
  || say "FAIL" "the binary on disk reports $(ver_on_disk "$SP/ok"), not $NEW"
# `updater-ships-only-what-it-can-install`: the half that used to be left behind
# was the bundle. If Info.plist still said $OLD the icon, the URL scheme and every
# permission string would be frozen at install time forever.
[ "$(plist_ver "$SP/ok")" = "$NEW" ] \
  && say "OK" "and so does Info.plist -- the whole bundle swapped, not just the binary" \
  || say "FAIL" "Info.plist still says $(plist_ver "$SP/ok") -- the bundle half did not land"
b1="$(grep -m1 -oE "^tk [0-9.]+" "$SP/ok.log" | awk '{print $2}')"
b2="$(grep -oE "^tk [0-9.]+" "$SP/ok.log" | tail -1 | awk '{print $2}')"
[ "$b1" = "$OLD" ] && [ "$b2" = "$NEW" ] \
  && say "OK" "and the process came back: it announced $b1, then $b2" \
  || say "FAIL" "banners went $b1 -> $b2, expected $OLD -> $NEW"
p1="$(grep -m1 -oE "^pid [0-9]+" "$SP/ok.log" | awk '{print $2}')"
p2="$(grep -oE "^pid [0-9]+" "$SP/ok.log" | tail -1 | awk '{print $2}')"
[ -n "$p1" ] && [ "$p1" = "$p2" ] \
  && say "OK" "in the same process ($p1) -- execv, not a relaunch nobody supervises" \
  || say "FAIL" "pid changed $p1 -> $p2; the re-exec did not happen"
# LAUNCH.md lists this as a regression that means the release is wrong: "Update
# still lands INTO THE SAME ROOM". `commit` re-execs with CommandLine.arguments,
# and a re-exec that dropped or re-minted the room would move somebody who is
# mid-call into an empty one -- for free here, because the argv is on the banner.
a2="$(grep -oE "^pid [0-9]+ argv: .*" "$SP/ok.log" | tail -1)"
case "$a2" in
  *"--room upd${$}ok"*) say "OK" "and back into the same room it was in, not a freshly minted one" ;;
  *) say "FAIL" "the new image came up with argv [$a2] -- the room did not survive the update" ;;
esac
[ -e "$SP/ok/.Kin.app.new" ] \
  && say "FAIL" "a staging bundle was left behind at $SP/ok/.Kin.app.new" \
  || say "OK" "and nothing was left beside the app"

# ── 2. TAMPERING IS REFUSED, AND THE APP STAYS WHERE IT IS ──────────────────
echo "2. the gate that must never weaken"
refused() { # <arm> <needle> <english>
  local a="$1"
  grep -q "$2" "$SP/$a.log" \
    && say "OK" "$3" \
    || say "FAIL" "$a: expected [$2] and got [$(grep -o 'update: .*' "$SP/$a.log" | tail -1)]"
  [ "$(ver_on_disk "$SP/$a")" = "$OLD" ] \
    && say "OK" "  and it is still on $OLD" \
    || say "FAIL" "  $a INSTALLED SOMETHING: the binary now reports $(ver_on_disk "$SP/$a")"
}
refused body "update: manifest signature INVALID" \
  "one byte edited in the manifest, signature kept -- refused by name"
[ "$(hits "dl/.*arm=body")" = "0" ] \
  && say "OK" "  and it never asked for the payload the edited manifest named" \
  || say "FAIL" "  it downloaded the payload of a manifest that failed verification"
refused sig "update: manifest signature INVALID" \
  "one byte flipped in the signature -- refused by name"
refused hash "update: sha256 mismatch (want 0000000000" \
  "a correctly signed manifest naming a hash the payload does not have -- refused"
refused tgz "update: sha256 mismatch (want $GOODSHA" \
  "one byte flipped in the tarball -- refused against the signed hash"
# CONTROL. Without this the four lines above are satisfied by a build that
# refuses everything, which is the shape of half the false passes in this repo.
grep -q "update: installed $NEW" "$SP/ok.log" \
  && say "OK" "CONTROL: the same code accepted the untampered release, so it discriminates" \
  || say "FAIL" "CONTROL: nothing was ever accepted, so the four refusals prove nothing"

# ── 3. A VERSION THAT IS NOT NEWER DOES NOTHING ────────────────────────────
echo "3. and a version that is not newer does nothing"
[ "$(hits "older/manifest.json HTTP")" -gt 0 ] \
  && say "OK" "it read the stale manifest $(hits "older/manifest.json HTTP") times" \
  || say "FAIL" "the poller never ran in the stale arm, so its silence means nothing"
[ "$(hits "dl/.*arm=older")" = "0" ] \
  && say "OK" "and never asked for the payload" \
  || say "FAIL" "it downloaded $OLDER over $OLD"
[ "$(ver_on_disk "$SP/older")" = "$OLD" ] \
  && say "OK" "and it is still $OLD" \
  || say "FAIL" "it went to $(ver_on_disk "$SP/older")"
[ "$(lines "$SP/older.log" "^tk ")" = "1" ] \
  && say "OK" "one launch, no restart" \
  || say "FAIL" "$(lines "$SP/older.log" "^tk ") launches -- something re-exec'd"

# ── 4. THE WATCHER KEEPS A CLOSED MAC CURRENT BY ITSELF ────────────────────
echo "4. tk --watch, with no app open"
W=$(hits "watch/manifest.json HTTP")
[ "$W" -gt 0 ] \
  && say "OK" "the watcher asked for a manifest $W times -- on its own, with no window anywhere" \
  || say "FAIL" "the watcher NEVER polled; Update.startPolling is unreachable under Watch.run again"
grep -q "watch: checking for a newer Kin" "$SP/watch.log" \
  && say "OK" "and it says so on the way in" \
  || say "FAIL" "no line announcing the watcher's poller"
grep -q "update: installed $NEW" "$SP/watch.log" \
  && say "OK" "it installed $NEW with nobody looking" \
  || say "FAIL" "the watcher polled and never installed: $(grep -o 'update: .*' "$SP/watch.log" | tail -1)"
[ "$(ver_on_disk "$SP/watch")" = "$NEW" ] \
  && say "OK" "and the bundle on disk is $NEW" \
  || say "FAIL" "the bundle on disk is $(ver_on_disk "$SP/watch")"
# It has to COME BACK, by one of the two routes it is allowed: execv in the
# updater, or exit 3 for launchd. A watcher that installs and dies with a clean
# exit is a Mac that stops answering the door until the next login.
if [ "$(lines "$SP/watch.log" "watch: checking for a newer Kin")" -gt 1 ]; then
  say "OK" "and came back in the same process (execv) -- it is watching again"
elif grep -q "watch: this Mac has a newer Kin -- restarting into it" "$SP/watch.log"; then
  say "OK" "and exited 3 for launchd to restart -- KeepAlive's failure case, deliberately"
else
  say "FAIL" "it installed and neither re-exec'd nor asked to be restarted"
fi
# The arm that makes all of that mean something.
N=$(hits "nowatch/manifest.json HTTP")
[ "$N" = "0" ] \
  && say "OK" "OPPOSITE ARM: --watch --no-update asked this server for nothing at all" \
  || say "FAIL" "--no-update still polled $N times -- the flag is decoration"
[ "$(ver_on_disk "$SP/nowatch")" = "$OLD" ] \
  && say "OK" "and stayed on $OLD" \
  || say "FAIL" "--no-update updated to $(ver_on_disk "$SP/nowatch")"
grep -q "watch: resident for" "$SP/nowatch.log" \
  && say "OK" "CONTROL: and it was a live watcher, not a process that failed to start" \
  || say "FAIL" "CONTROL: the --no-update watcher never started, so its silence is its own"

# ── 5. THE CADENCE OVERRIDES ARE REAL ──────────────────────────────────────
echo "5. TK_UPDATE_GRACE and TK_UPDATE_POLL"
fa=$(first_hit "GET /cadA/manifest.json" "$CA0")
fb=$(first_hit "GET /cadB/manifest.json" "$CB0")
ca=$(hits "cadA/manifest.json HTTP"); cb=$(hits "cadB/manifest.json HTTP")
[ "$fa" -ge 0 ] && [ "$fb" -ge 0 ] \
  && say "OK" "both arms polled: grace 2 first asked at ${fa}s, grace 8 at ${fb}s" \
  || say "FAIL" "one of the cadence arms never polled at all (${fa}s / ${fb}s)"
[ "$fa" -ge 0 ] && [ "$fb" -ge 0 ] && [ "$((fb - fa))" -ge 4 ] \
  && say "OK" "and TK_UPDATE_GRACE moved the first ask by $((fb - fa)) s -- it is not decoration" \
  || say "FAIL" "the first ask barely moved (${fa}s vs ${fb}s); TK_UPDATE_GRACE may do nothing"
[ "$ca" -gt "$cb" ] \
  && say "OK" "and TK_UPDATE_POLL: $ca asks at 2 s against $cb at 8 s in the same window" \
  || say "FAIL" "poll=2 made $ca asks and poll=8 made $cb -- the interval is not being read"

# ── 6. AN INSTALL THE USER CANNOT WRITE ────────────────────────────────────
echo "6. a copy this account cannot write (the non-admin /Applications case)"
grep -q "update: cannot stage a bundle next to" "$SP/ro.log" \
  && say "OK" "the bundle swap refused rather than half-replacing anything" \
  || say "FAIL" "no refusal from swapBundle: $(grep -o 'update: .*' "$SP/ro.log" | tail -1)"
[ "$(ver_on_disk "$SP/ro")" = "$OLD" ] \
  && say "OK" "and the app is intact and still on $OLD" \
  || say "FAIL" "a read-only install ended up at $(ver_on_disk "$SP/ro")"
# ── AND THE PART NOBODY WOULD EVER SEE ──────────────────────────────────────
#
# `pending` is only ever set when a call is live. A commit that FAILS drops the
# staged copy on the floor, so the next tick fetches the whole archive again --
# forever, at the poll interval, on a machine that can never succeed. Counted
# rather than argued: this is the number of times a Mac that cannot update
# downloaded a release it could not install.
RD=$(hits "dl/.*arm=ro")
[ "$RD" -gt 1 ] \
  && say "OK" "MEASURED: it re-downloaded the whole release $RD times in 14 s and will not stop" \
  || say "OK" "it downloaded the release $RD time(s)"
grep -qE "update .* (Applications|admin|permission|administrator)" "$SP/ro.log" \
  && say "OK" "and something explains it in words" \
  || say "OK" "NOTE: nothing a person could see says why -- both messages are stderr, and the app's status line is never told"
# The arm that ranks the other way: the writable install fetched the payload once.
OD=$(hits "dl/.*arm=ok")
[ "$OD" -le 1 ] \
  && say "OK" "OPPOSITE ARM: the writable install downloaded it $OD time and stopped" \
  || say "FAIL" "even the writable install downloaded $OD times"

# ── 7. TWO UPDATERS, ONE BUNDLE ────────────────────────────────────────────
echo "7. the watcher and the app updating the same bundle at once"
RW=$(lines "$SP/race-w.log" "update: installed $NEW")
RF=$(lines "$SP/race-f.log" "update: installed $NEW")
say "OK" "installs claimed: watcher $RW, app $RF -- two processes, one bundle, one release"
cat "$SP/race-w.log" "$SP/race-f.log" > "$SP/race-both.log" 2>/dev/null
seen=0
for w in "cannot stage a bundle next to" "bundle swap failed" "candidate will not launch" \
         "staged payload for $NEW is gone" "archive has neither tk nor a bundle" \
         "sha256 mismatch" "download failed" "execv failed"; do
  n=$(lines "$SP/race-both.log" "$w")
  if [ "$n" -gt 0 ]; then say "OK" "  collision observed: \"$w\" x$n"; seen=1; fi
done
[ "$seen" = 0 ] && say "OK" "  no collision surfaced on this run -- it is a race, so absence here is not proof of safety"
[ "$(ver_on_disk "$SP/race")" = "$NEW" ] \
  && say "OK" "and the bundle still launches and reports $NEW" \
  || say "FAIL" "TWO UPDATERS BRICKED THE BUNDLE: it now reports $(ver_on_disk "$SP/race")"
# ── AND "IT STILL LAUNCHES" IS NOT THE QUESTION ─────────────────────────────
#
# It was, and the arm passed a build that installs CORRUPT bundles. Two `ditto`s
# into one staging path do not produce a broken executable -- they produce a
# complete-looking bundle with files missing from the END of the copy, which runs
# perfectly and reports the right version. `codesign --verify` on such a bundle
# says "invalid resource directory" or "a sealed resource is missing", and the
# designated requirement is what macOS pins a camera or microphone grant to. So
# the install is compared FILE FOR FILE against the payload that was served.
INST="$(cd "$SP/race/Kin.app" 2>/dev/null && find . -type f | sort | wc -l | tr -d ' ')"
MISSING="$(comm -23 <(cd "$SP/pkg/Kin.app" && find . -type f | sort) \
                    <(cd "$SP/race/Kin.app" 2>/dev/null && find . -type f | sort) | wc -l | tr -d ' ')"
[ "${MISSING:-1}" = "0" ] \
  && say "OK" "and it is COMPLETE -- $INST of $PAYFILES files, none missing" \
  || say "FAIL" "the installed bundle is missing $MISSING of $PAYFILES files: a half-copy was swapped in atomically, it launches, and its signature no longer verifies"
LEFT="$(ls -d "$SP/race/".Kin.app.new* 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFT" = "0" ] \
  && say "OK" "and no staging copy was left behind" \
  || say "OK" "NOTE: $LEFT staging copy left behind (this rig SIGKILLs mid-update; the next update sweeps dead-pid copies)"

echo
if [ "$fail" = 0 ]; then
  echo "UPDATE CHECK PASSED -- a signed release lands, a tampered one never does,"
  echo "and the watcher keeps a closed Mac current by itself"
else
  echo "UPDATE CHECK FAILED -- see above; logs copied to $OUT/update-*.log"
  for f in probe ok older body sig hash tgz watch nowatch ro race-w race-f cadA cadB; do
    cp "$SP/$f.log" "$OUT/update-$f.log" 2>/dev/null
  done
  cp "$SP/srv.log" "$OUT/update-server.log" 2>/dev/null
fi
exit $fail
