#!/bin/bash
# ── PATCHING A SIGNED BUNDLE MAKES THE APP UNLAUNCHABLE ──────────────────────
#
# The field crash this file exists for, 2026-09-01 08:50, version 0.114.0:
#
#     Exception:    EXC_CRASH (SIGKILL (Code Signature Invalid))
#     Termination:  CODESIGNING, Code 4, Launch Constraint Violation
#     Launch 08:50:20.3473 -> dead 08:50:20.4314     (84 ms, frames: [])
#     Parent: launchd [1]   Coalition: com.tokkah.tk.watch
#
# `Update.installBundle` -- the legacy path for archives that predate the
# whole-bundle payload -- wrote `Info.plist` and `Contents/Resources/AppIcon.icns`
# into the app it was running from. Both are sealed by
# `_CodeSignature/CodeResources`, so the signature stopped verifying and the
# kernel refused every launch afterwards. The parent is the login item, so the
# visible symptom was "Calls when Kin is closed" quietly not working: launchd
# starts it, the kernel kills it before `main`, and the app never runs far enough
# to log anything at all.
#
# THREE THINGS, and the third is the one that makes this a test rather than an
# opinion:
#
#   1  a bundle signed with the release certificate verifies, and its designated
#      requirement names the certificate rather than a content hash
#   2  rewriting ONE sealed file breaks it -- so the hazard is real, and
#      `codesign --verify` can see it. Without this arm, "the app still verifies"
#      would be equally consistent with a checker that always says yes.
#   3  what launchd then does about it -- MEASURED, not asserted, because the
#      measurement refuted the guess. A broken seal alone is survivable on this
#      macOS; see the note beside that arm for the second candidate cause and why
#      `verifyInstalled` checks with codesign rather than with a launch.
#
# Then the product's own guard: a certificate-signed install must DECLINE to patch
# itself, and say so.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
: "${KIN_SIGNING_ENV:=$HOME/.config/kin-signing/env}"
[ -f "$KIN_SIGNING_ENV" ] || {
  echo "SEAL CHECK COULD NOT RUN -- no signing identity at $KIN_SIGNING_ENV."
  echo "  Every arm here is about what a CERTIFICATE signature does; an ad-hoc"
  echo "  one has a different failure mode and would prove nothing."
  exit 2; }
SP="$(mktemp -d)"
echo "scratch: $SP"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }

# ── 1. A SIGNED BUNDLE ───────────────────────────────────────────────────────
# Built by the same script release.sh uses, so this is the artefact people
# actually install and not a hand-rolled imitation of one.
# ── A PROBE VERSION THAT CANNOT OUTRANK PRODUCTION ──────────────────────────
#
# This said `9.9.9-seal`, and that one choice cost the user their install. The
# bundles built here are launched (arms 3 and 4), they live outside /Applications,
# and `Install.relocateIfHomeless` exists precisely to move such a bundle INTO
# /Applications and hand over to it. `Install.install` has a downgrade guard and it
# worked exactly as written -- it declined to treat the installed 0.118.0 as newer
# than 9.9.9 -- so the probe was allowed to overwrite a working release, and
# /Applications/Kin.app reported `9.9.9-seal` afterwards. Worse than a wrong label:
# every later update comparison would have found 0.119.0 OLDER than 9.9.9 and the
# app would never have updated itself again.
#
# `Install.swift`'s own comment records the first instance of this ("that happened,
# and the install had to be restored from prod"). This is the second. So two
# guards, not one:
#
#   0.0.1-seal   a version below every real release, so the downgrade guard
#                catches a relocation even if the flag below is ever dropped
#   --no-relocate  on every launch, which is the documented rule
bash bundle/mkapp.sh 0.0.1-seal "$TK" "$SP" > "$SP/mkapp.log" 2>&1 || {
  echo "SEAL CHECK COULD NOT RUN -- mkapp.sh failed:"; sed 's/^/  /' "$SP/mkapp.log"; exit 2; }
APP="$SP/Kin.app"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  say OK "a freshly built bundle verifies"
else
  say FAIL "mkapp.sh produced a bundle that does not verify"; fail=1
fi
DR="$(codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
case "$DR" in
  *"certificate root"*) say OK "and its requirement names the certificate: $DR" ;;
  *) say FAIL "the requirement is not certificate-based, so no arm below means anything: $DR"; fail=1 ;;
esac

# ── 2. ONE SEALED FILE, REWRITTEN ────────────────────────────────────────────
# THE ARM THAT MUST FAIL. `Info.plist` is exactly what the updater used to
# rewrite, and it is rewritten here the same way -- read, substitute, write back.
cp -R "$APP" "$SP/Broken.app"
python3 - "$SP/Broken.app/Contents/Info.plist" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", errors="replace").read()
# The same shape the updater used: fill a version in and write the file back.
io.open(p, "w", encoding="utf-8").write(s.replace("0.0.1-seal", "0.0.2-seal"))
PY
if codesign --verify --deep --strict "$SP/Broken.app" 2>/dev/null; then
  say FAIL "rewriting Info.plist did NOT break the seal -- this whole file is measuring nothing"
  fail=1
else
  say OK "rewriting Info.plist breaks the seal: $(codesign --verify --deep --strict "$SP/Broken.app" 2>&1 | head -1 | sed 's|.*Kin.app: ||;s|.*Broken.app: ||')"
fi

# ── 3. AND launchd CANNOT START IT ───────────────────────────────────────────
#
# The field symptom, on the path that produced it. WHICH PATH MATTERS: run
# straight from a shell, the broken bundle starts and prints its version quite
# happily, because exec validates the Mach-O's own signature and the executable
# was never touched -- only the resource seal was. The kernel's launch-constraint
# check is what refuses it, and the crash report says who asked for that check:
#
#     Parent Process: launchd [1]   Coalition: com.tokkah.tk.watch
#
# So the job is put in front of launchd, exactly as the login item is, and
# launchd's own accounting is read back. `--version` prints and exits 0 before
# touching anything, so a non-zero status here is the operating system's answer
# and not the program's.
LABEL="com.tokkah.tk.sealrig$$"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOM="gui/$(id -u)"
seal_job() {                       # seal_job <app> <out>
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$1/Contents/MacOS/Tokkah</string><string>--version</string><string>--no-relocate</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$2</string>
<key>StandardErrorPath</key><string>$2.err</string>
</dict></plist>
EOF
  : > "$2"
  /bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null
  w=0; while /bin/launchctl print "$DOM/$LABEL" >/dev/null 2>&1 && [ $w -lt 40 ]; do sleep 0.25; w=$((w+1)); done
  /bin/launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null || return 1
  # ── WAIT FOR AN ANSWER, NOT FOR THE FIELD THAT HOLDS ONE ──────────────────
  # `last exit code` is printed from the moment the job is loaded, reading
  # `(never exited)` until it has actually run -- so a loop that waits for the
  # FIELD returns immediately and both arms read "never exited", which is the
  # same non-answer for a job that ran and one that was killed. Wait for the
  # outcome: output on stdout, or an exit code that is a number, or a signal.
  w=0
  while [ $w -lt 80 ]; do
    [ -s "$2" ] && break
    /bin/launchctl print "$DOM/$LABEL" 2>/dev/null \
      | grep -qE 'last exit code = [0-9]+|last exit reason' && break
    sleep 0.25; w=$((w+1))
  done
  /bin/launchctl print "$DOM/$LABEL" 2>/dev/null \
    | grep -E 'last exit (code|reason)' | head -1 | sed 's/^[[:space:]]*//'
}
trap '/bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null; rm -f "$PLIST"; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
BROKEN_EXIT="$(seal_job "$SP/Broken.app" "$SP/broken.out")"
GOOD_EXIT="$(seal_job "$APP" "$SP/good.out")"
# CONTROL FIRST, because arm 3 is worthless if the good bundle cannot run either:
# that would make "it did not start" a statement about this binary, not about the
# seal. `--version` prints the version compiled into the source, which is not the
# 0.0.1-seal in the plist -- so the assertion is that it printed SOMETHING.
if [ -s "$SP/good.out" ]; then
  say OK "CONTROL: launchd runs the untouched bundle -- it printed $(tr -d '\n' < "$SP/good.out")"
else
  say FAIL "CONTROL: launchd could not run the untouched bundle either ($GOOD_EXIT), so arm 3 proves nothing"
  fail=1
fi
# ── AND WHAT THAT MEASUREMENT ACTUALLY SAID ─────────────────────────────────
#
# Not an assertion, because it refuted the guess it was written to confirm. A
# broken resource seal, on macOS 27 on this Mac, does NOT by itself stop launchd:
# the job ran and printed its version. So the 84 ms SIGKILL in the field was not
# caused by the seal ALONE -- the legacy path also renames a bare `tk` over
# `Contents/MacOS/Tokkah`, and a bare binary's embedded signature carries the
# identifier `tk` rather than `com.tokkah.tk`, which is a second way to end up with
# a bundle the kernel refuses.
#
# Recorded here rather than deleted, because "we thought it was the seal and the
# seal alone is survivable" is exactly the sort of thing that gets re-guessed. The
# claims this file DOES make are arm 2 (the seal really breaks, and codesign sees
# it) and arm 4 (the app will not create that state) -- and `verifyInstalled` runs
# `codesign --verify --deep --strict` after a legacy install, which catches either
# cause without needing to know which one bit.
if [ -s "$SP/broken.out" ]; then
  say note "a broken seal alone did NOT stop launchd here (it printed $(tr -d '\n' < "$SP/broken.out"))"
  say note "-- so codesign, not the launch, is the instrument that catches this"
else
  say note "launchd would not start the broken bundle -- ${BROKEN_EXIT:-no output, no exit recorded}"
fi

# ── 4. SO THE PRODUCT MUST DECLINE TO DO IT ──────────────────────────────────
# `installBundle` is reached only from the legacy update path, which needs an
# archive with no `Kin.app/` in it -- more machinery than this file should own
# (`update-check.sh` has it). What IS reachable from here is the decision: the
# guard is `isCertificateSigned()`, the same predicate `repairBundleIfStale` has
# used for months, and `--selftest-seal` asks the running copy for its answer.
SIGNED="$("$APP/Contents/MacOS/Tokkah" --selftest-seal --no-relocate 2>&1)"
case "$SIGNED" in
  *"certificate-signed: yes"*) say OK "a signed copy knows it is signed -- so the guard declines: $SIGNED" ;;
  *"certificate-signed: no"*) say FAIL "a certificate-signed copy reports NO, so the guard would patch it: $SIGNED"; fail=1 ;;
  *) say FAIL "--selftest-seal said nothing usable: $SIGNED"; fail=1 ;;
esac
# CONTROL: an ad-hoc copy must report the other way, or the predicate is a
# constant and the guard would refuse to refresh anything, ever.
cp -R "$APP" "$SP/Adhoc.app"
codesign --force --sign - "$SP/Adhoc.app" >/dev/null 2>&1
ADHOC="$("$SP/Adhoc.app/Contents/MacOS/Tokkah" --selftest-seal --no-relocate 2>&1)"
case "$ADHOC" in
  *"certificate-signed: no"*) say OK "CONTROL: an ad-hoc copy reports NO, so those are still refreshed" ;;
  *) say FAIL "CONTROL: an ad-hoc copy reports [$ADHOC] -- the predicate is a constant"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "SEAL CHECK PASSED -- the seal is real, codesign sees it break, and the app will not break it" \
                || echo "SEAL CHECK FAILED"
exit $fail
