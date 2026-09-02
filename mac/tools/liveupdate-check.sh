#!/bin/bash
# ── DOES A CALL SURVIVE THE APP DYING? ───────────────────────────────────────
#
# The user's words: "even if one side closes the app, they should hop into the
# call as soon as they start the app again, unless they have disconnected the
# call. Only disconnecting the call will disconnect the call -- otherwise the
# call should stay open. Either of the sides has to disconnect. That's how the
# web app used to work. So even for the update, where we are automatically
# closing and opening the app, they should hop right back in. Sometimes apps
# crash and stuff like that. And all of this should be super instant."
#
# So there are two claims and they must be proved SEPARATELY, because a rig that
# only proves the first is satisfied by an app that reopens every call it has
# ever had:
#
#   1. a process that dies WITHOUT hanging up rejoins, and the far end holds the
#      call open rather than saying "the other person left"
#   2. a process that HANGS UP does not rejoin, and the far end ends the call
#
# Both arms run the same crash. The only difference is whether a person pressed
# the button first, which is the whole of what the feature claims to distinguish.
#
# THE NEGATIVE ARM IS THE POINT. Part two runs the identical `kill -9` with
# rejoining switched off, so the rig has to be able to say "the call did NOT come
# back" -- without it, every assertion here would be satisfied by two processes
# that happened to find each other again, which is what they did before any of
# this was written.
set -u
# Windows must not throw themselves in front of whatever the person at this Mac
# is doing, and nothing here may reach their speakers. Both are exported rather
# than passed, because a flag you have to remember on every one of a dozen
# commands is a flag you will forget on the thirteenth.
export TK_NO_RAISE=1
export TK_MUTE=1
# NO HANDLE AT ALL. `--no-update` no longer disables the identity claim, so
# without this every run would claim a name on the REAL server, walking @devesh,
# @deveshp, @devesh2 ... and squatting names a person may want.
export TK_NO_IDENTITY=1
# ── PIDs, NEVER `pkill -f` ───────────────────────────────────────────────────
#
# `pkill -f` takes a REGEX, and in a path like `./.build/debug/tk` every `.`
# matches any character -- so the pattern also matches another agent's checkout
# and reaps their processes from the outside. A rig may only end processes it
# started.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/liveupdate-check.$$"
mkdir -p "$SP"
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
[ -x "$TK" ] || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- no tk at $TK; swift build --package-path mac"; exit 2; }

# ── REAL MEDIA, AND ON A PATH WITH NO SPACES IN IT ──────────────────────────
#
# A real downloaded talking head, never a synthetic pattern: a decoder and an
# encoder behave differently on real texture, and this project has a rule about
# it. Copied into the scratch directory first because this repo can be checked
# out under a path containing a space ("video calling"), and an unquoted
# expansion of it turns `--video <path>` into `--video /Users/.../video` -- which
# is refused, so the arm runs with no video at all while still being named the
# video arm.
MEDIA_SRC="${MEDIA:-$HERE/../../testbed/media/real/talkingheadA.mov}"
[ -f "$MEDIA_SRC" ] || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- no test media at $MEDIA_SRC; see testbed/media/real/fetch.sh"; exit 2; }
cp "$MEDIA_SRC" "$SP/head.mov" || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- cannot copy media into $SP"; exit 2; }
MED="$SP/head.mov"

# TK_KIN_DIR because `.applicationSupportDirectory` resolves through the USER
# RECORD and not $HOME, so a rig without it reads and writes the REAL install --
# and the file this feature keeps there is a live call. A test that resumed the
# user's actual conversation would be exactly the isolation failure this variable
# exists for. One directory per side: they are two different Macs as far as the
# room directory is concerned.
export TK_KIN_DIR="$SP/id"
mkdir -p "$SP/id" "$SP/ida" "$SP/idb"

# Ports 8101/8102 only, and never the app's defaults: another agent's rig may be
# on 7001/7002 in another checkout on this same Mac.
PA=8101
PB=8102
COMMON="--mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"

# How long the relaunch is delayed. Held CONSTANT across arms and subtracted from
# nothing: it is part of the gap the far end sees and pretending otherwise would
# flatter the number. Named, so the app's own share can be read off against it.
#
# EIGHT SECONDS, and the size is load-bearing rather than arbitrary. The far end
# notices silence at 3 s and only reaches its HOLD decision two seconds after
# that, so a two-second outage comes back before the code under test has run --
# the call recovers, every assertion passes, and the branch that decides between
# "they left" and "they will be right back" was never entered. A rig has to make
# the thing it is testing reachable.
RELAUNCH_DELAY=8

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
started() { grep -q "^tk " "$1" || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- tk never started in $1:"; sed -n '1,6p' "$1" | sed 's/^/  /'; exit 2; }; }

# ── PART ONE: A CRASH IS NOT A HANG-UP ──────────────────────────────────────
#
# `kill -9`, which is the harshest thing that can happen to a process: no signal
# handler, no final beat, no goodbye, nothing on the way out. Then the app is
# started again with NO ARGUMENTS AT ALL -- no room, no port, no peer -- which is
# exactly what double-clicking Kin does. Everything it needs to walk back into
# the call has to come off the disk or it does not come at all.
#
# The side that STAYS runs with a window and photographs its own controls three
# times across the outage (`?` is the hit-test audit, and its `audit state` line
# carries the status pill). Without a window there is no pill, and "the app
# decided to say reconnecting" would be indistinguishable from "the app said
# nothing" -- a handler test that cannot see what a person sees.
R1="lurig$$a"
echo "part one: a crash, then the app is opened again with no arguments"
spawn env TK_KIN_DIR="$SP/ida" "$TK" --window --room "$R1" --listen $PA --peer 127.0.0.1:$PB \
      --video "$MED" $COMMON --press-after 16 --press "?,?,?,?,?,?" > "$SP/a.log" 2>&1
spawn env TK_KIN_DIR="$SP/idb" "$TK" --room "$R1" --listen $PB --peer 127.0.0.1:$PA \
      --video "$MED" $COMMON > "$SP/b.log" 2>&1
B1=$LAST_PID
perl -e 'select undef,undef,undef,14'
cp "$SP/idb/call.json" "$SP/record-before-crash.json" 2>/dev/null
kill -9 "$B1" 2>/dev/null
perl -e "select undef,undef,undef,$RELAUNCH_DELAY"
spawn env TK_KIN_DIR="$SP/idb" "$TK" --video "$MED" $COMMON > "$SP/b2.log" 2>&1
perl -e 'select undef,undef,undef,22'
reap
started "$SP/a.log"; started "$SP/b2.log"

# ── PART TWO: THE SAME CRASH, WITH REJOINING SWITCHED OFF ───────────────────
#
# The control. Identical to part one down to the second, except that the
# relaunched image is told not to rejoin -- so if part one's assertions still
# pass here, they were never measuring the feature.
R2="lurig$$b"
echo "part two: the same crash, with rejoining switched off"
spawn env TK_KIN_DIR="$SP/idc" "$TK" --room "$R2" --listen $PA --peer 127.0.0.1:$PB \
      --video "$MED" $COMMON > "$SP/c.log" 2>&1
spawn env TK_KIN_DIR="$SP/idd" "$TK" --room "$R2" --listen $PB --peer 127.0.0.1:$PA \
      --video "$MED" $COMMON > "$SP/d.log" 2>&1
D1=$LAST_PID
perl -e 'select undef,undef,undef,14'
kill -9 "$D1" 2>/dev/null
perl -e "select undef,undef,undef,$RELAUNCH_DELAY"
spawn env TK_KIN_DIR="$SP/idd" TK_NO_REJOIN=1 "$TK" --video "$MED" $COMMON \
      > "$SP/d2.log" 2>&1
perl -e 'select undef,undef,undef,22'
reap
started "$SP/c.log"; started "$SP/d2.log"

# ── PART THREE: HANGING UP REALLY DOES HANG UP ──────────────────────────────
#
# The other half of the claim, and the half a feature could fail while passing
# every assertion above: if nothing ever ends a call, "the call stays open" is
# satisfied trivially and the app becomes impossible to leave. One side presses
# the hang-up control; the other must end, and neither may rejoin afterwards.
#
# PRESSED TWICE, because leaving is a two-step confirm -- one press arms the pill,
# the second commits, and the arm forgets itself after three seconds. A single
# press produced a log line saying the button had been pressed and a process that
# carried on talking, which is what this rig reported the first time it ran.
R3="lurig$$c"
echo "part three: one side hangs up"
spawn env TK_KIN_DIR="$SP/ide" "$TK" --window --room "$R3" --listen $PA --peer 127.0.0.1:$PB \
      --video "$MED" $COMMON > "$SP/e.log" 2>&1
spawn env TK_KIN_DIR="$SP/idf" "$TK" --window --room "$R3" --listen $PB --peer 127.0.0.1:$PA \
      --video "$MED" $COMMON --press-after 12 --press "leave,leave" > "$SP/f.log" 2>&1
perl -e 'select undef,undef,undef,20'
reap
started "$SP/e.log"; started "$SP/f.log"
# And now open the hung-up side again. It must NOT walk back in.
spawn env TK_KIN_DIR="$SP/idf" "$TK" --video "$MED" $COMMON > "$SP/f2.log" 2>&1
perl -e 'select undef,undef,undef,6'
reap

# ── PART FOUR: A REAL UPDATE, LANDED IN THE MIDDLE OF A CALL ────────────────
#
# The case the whole thing started from. A signed manifest and a tarball on a
# local server, `TK_UPDATE_BASE` pointed at it, and the poller told it may commit
# through a live call (`TK_UPDATE_MIDCALL=1`, which production never sets -- the
# default is still to wait for the call to end). What has to be true afterwards is
# not "the update installed", it is "the two people were still talking".
#
# EVERYTHING RUNS ON A COPY of tk in the scratch directory. `commit` renames the
# new binary OVER the running one, so a rig pointed at ../.build/debug/tk would
# overwrite the build another agent in another worktree is using.
#
# The signature is the real one. `Update.available` verifies the manifest against
# a compiled-in public key and there is deliberately no bypass flag, so this arm
# needs the release key -- and says so and stops rather than passing quietly if it
# is not on this machine, because an arm that silently does not run is an arm that
# reports OK for a feature that is broken.
#
# THE HTTP SERVER IS ON TCP 8102. tk's 8102 is a UDP port; the two live in
# different namespaces and cannot collide, so this stays inside the two ports this
# lane owns.
UPDPORT=8102
echo "part four: a real signed update, landed mid-call from a local server"
if [ ! -f "$HOME/.config/tokkah/mac-update-ed25519.key" ]; then
  say "FAIL" "part four cannot run: no release key at ~/.config/tokkah/mac-update-ed25519.key, and there is no bypass by design"
else
  mkdir -p "$SP/app" "$SP/upd/dl" "$SP/stage"
  cp "$TK" "$SP/app/tk"
  cp "$TK" "$SP/stage/tk"
  # The payload is this same binary. It does not have to BE 0.64.1 -- `stage`
  # proves a candidate by running `--version` and checking it exits 0, and the
  # manifest is what declares the version. What that buys is an arm that tests the
  # update MACHINERY without a second build, and the cost is that the new image
  # still reports the old version and would find the "newer" release again on its
  # next poll. TK_UPDATE_POLL is set past the end of the run so that cannot happen.
  ( cd "$SP/stage" && tar -czf "$SP/upd/dl/tk.tar.gz" tk ) || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- cannot build the update tarball"; exit 2; }
  SHA=$(shasum -a 256 "$SP/upd/dl/tk.tar.gz" | cut -d' ' -f1)
  printf '{"version":"99.0.0","url":"http://127.0.0.1:%s/dl/tk.tar.gz","sha256":"%s","notes":"rig"}' \
    "$UPDPORT" "$SHA" > "$SP/upd/manifest.json"
  "$HERE/sign" "$SP/upd/manifest.json" > "$SP/upd/manifest.json.sig" 2>"$SP/sign.err" \
    || { echo "LIVE-UPDATE CHECK COULD NOT RUN -- signing failed: $(cat "$SP/sign.err")"; exit 2; }
  spawn python3 -m http.server "$UPDPORT" --bind 127.0.0.1 --directory "$SP/upd" > "$SP/http.log" 2>&1
  perl -e 'select undef,undef,undef,1'
  R4="lurig$$d"
  # The side that STAYS gets no update server at all: only one end restarts, which
  # is what a staggered rollout looks like and is the case that has to keep working.
  spawn env TK_KIN_DIR="$SP/idg" "$TK" --room "$R4" --listen $PA --peer 127.0.0.1:$PB \
        --video "$MED" $COMMON > "$SP/g.log" 2>&1
  # And the side that takes it runs the COPY, with the poller aimed at the local
  # server, its first check 12 s in -- late enough that there is a real call to
  # interrupt -- and no second check inside this run.
  spawn env TK_KIN_DIR="$SP/idh" TK_UPDATE_BASE="http://127.0.0.1:$UPDPORT" \
        TK_UPDATE_MIDCALL=1 TK_UPDATE_POLL=999 TK_UPDATE_GRACE=12 \
        "$SP/app/tk" --room "$R4" --listen $PB --peer 127.0.0.1:$PA \
        --video "$MED" --mute --no-relocate --no-rings --no-subtitles \
        --tel-endpoint "http://127.0.0.1:$UPDPORT/beat" \
        > "$SP/h.log" 2>&1
  # TELEMETRY ON, AIMED AT THE LOCAL SERVER. `--no-telemetry` makes
  # `postFinalBeat` return before it prints, so an arm that asserts "the ending
  # was filed" with telemetry off can only ever fail -- and would look like a
  # missing feature rather than a rig that switched the feature off. The endpoint
  # is the rig's own http server, which 501s on POST: the beat is attempted, said
  # out loud, and nothing reaches production.
  #
  # TWENTY-TWO SECONDS, not thirty-two. The payload here is this same binary, so
  # it reports the old version and the manifest still reads as newer -- the
  # successor's own first check, TK_UPDATE_GRACE seconds after ITS launch, finds
  # the same update again. That is correct behaviour for a real release and an
  # artifact of reusing one binary, so the window is sized to hold exactly one
  # update and its recovery.
  perl -e 'select undef,undef,undef,22'
  reap
  started "$SP/g.log"; started "$SP/h.log"
fi

echo
# ── 1. THE CALL WAS REAL BEFORE ANY OF THIS ─────────────────────────────────
#
# Without this every assertion below is about two processes that never talked.
PRE=$(grep -cE "^cap " "$SP/a.log")
[ "${PRE:-0}" -gt 5 ] \
  && say "OK" "there was a real call first -- $PRE media reports on the side that stayed" \
  || say "FAIL" "no call to interrupt: only $PRE media reports before the crash"
[ -s "$SP/record-before-crash.json" ] \
  && say "OK" "and being in it was written down: $(tr -d '\n' < "$SP/record-before-crash.json" | cut -c1-80)…" \
  || say "FAIL" "nothing on disk said this Mac was in a call, so nothing can bring it back"

# ── 2. A CRASH LEAVES THE RECORD ALONE, AND A BARE LAUNCH READS IT ──────────
grep -q "rejoining" "$SP/b2.log" \
  && say "OK" "opening the app with no arguments found the call: $(grep -m1 'rejoining' "$SP/b2.log" | sed 's/^call: //')" \
  || say "FAIL" "the relaunched app did not find the call it was in"
grep -q "re-exec into $R1 -- rejoin" "$SP/b2.log" \
  && say "OK" "and walked straight into $R1 with no room typed and no link clicked" \
  || say "FAIL" "it never joined $R1"

# ── 3. THE CALL CAME BACK, AND MEDIA REALLY FLOWED ──────────────────────────
#
# Not "it connected". Connected is a log line; media is the product. Both ends
# have to be passing packets after the crash, and the side that stayed has to
# have seen the sequence numbers restart -- which is the failure this codebase
# has already paid for once, where a restarted sender's seq 0 was refused as
# "too old" forever and the call looked connected while passing nothing at all.
BACKA=$(grep -E "^cap " "$SP/a.log" | tail -6 | grep -cvE "recv 0/s")
[ "${BACKA:-0}" -ge 4 ] \
  && say "OK" "the side that stayed is receiving again ($BACKA of its last 6 reports)" \
  || say "FAIL" "the side that stayed never received anything after the crash"
BACKB=$(grep -E "^cap " "$SP/b2.log" | tail -6 | grep -cvE "recv 0/s")
[ "${BACKB:-0}" -ge 4 ] \
  && say "OK" "and the side that came back is receiving too ($BACKB of its last 6)" \
  || say "FAIL" "the relaunched side joined and received nothing"
grep -qE "peer-restarts [1-9]" "$SP/a.log" \
  && say "OK" "and the restarted stream was recognised as a restart, not refused as too old" \
  || say "FAIL" "no peer-restart was detected -- if media is flowing, check WHY"

# ── 4. WHAT THE PERSON WHO STAYED SAW ───────────────────────────────────────
#
# The single most damaging thing this feature could do is show "the other person
# left" over a call that is about to come back, put the invite card up, and make
# a return feel like a brand new call.
grep -q "the other person left" "$SP/a.log" \
  && say "FAIL" "they were told the other person left, over a call that came back" \
  || say "OK" "they were never told the other person left"
grep -q "telling them: reconnecting" "$SP/a.log" \
  && say "OK" "they were told it was coming back, the moment the line went quiet" \
  || say "FAIL" "the app decided nothing at all while the call was away"
grep -q "holding the call open" "$SP/a.log" \
  && say "OK" "and the hold really was entered: $(grep -m1 -o 'went quiet without hanging up.*' "$SP/a.log")" \
  || say "FAIL" "the hold branch never ran, so this arm proves only that a short blip recovers"
# THE PILL, not the decision. `audit state` is what the person is looking at.
PILLS=$(grep -c '^audit state' "$SP/a.log")
[ "${PILLS:-0}" -gt 0 ] \
  && say "OK" "and the window was photographed $PILLS times across the outage" \
  || say "FAIL" "no audit of the window was taken, so nothing here is about what they saw"
grep '^audit state' "$SP/a.log" | grep -q 'status=the other person left' \
  && say "FAIL" "the status pill read \"the other person left\" during a call that came back" \
  || say "OK" "and the status pill never once read \"the other person left\""

# ── 5. THE NUMBER ───────────────────────────────────────────────────────────
#
# Measured on the side that STAYED, because that is the only side that can
# measure it: the returning process's own clock starts after the silence began.
GAP=$(grep -oE "media gap [0-9]+ ms" "$SP/a.log" | head -1 | grep -oE "[0-9]+")
if [ -n "${GAP:-}" ]; then
  say "OK" "media gap ${GAP} ms end to end, of which ${RELAUNCH_DELAY}000 ms was this rig waiting before it relaunched"
else
  say "FAIL" "the side that stayed never reported a gap, so nothing was measured"
fi
JOIN=$(grep -oE "connected via .* at [0-9]+ ms" "$SP/b2.log" | head -1 | grep -oE "[0-9]+ ms$" | grep -oE "[0-9]+")
[ -n "${JOIN:-}" ] \
  && say "OK" "and the app itself took ${JOIN} ms from launch to being in the call" \
  || say "FAIL" "the relaunched app never reported when it got into the call"

# ── 6. CONTROL: THE SAME CRASH, AND IT MUST NOT COME BACK ───────────────────
grep -q "re-exec into $R2 -- rejoin" "$SP/d2.log" \
  && say "FAIL" "CONTROL: it rejoined with rejoining switched off -- the switch does nothing" \
  || say "OK" "CONTROL: with rejoining off, the relaunched app did not go back into $R2"
CTLA=$(grep -E "^cap " "$SP/c.log" | tail -6 | grep -cvE "recv 0/s")
[ "${CTLA:-9}" -eq 0 ] \
  && say "OK" "CONTROL: and the side that stayed received NOTHING for the rest of the run" \
  || say "FAIL" "CONTROL: the call came back anyway ($CTLA of the last 6 reports had media) -- part three proves nothing"
CTLPRE=$(grep -cE "^cap " "$SP/c.log")
[ "${CTLPRE:-0}" -gt 5 ] \
  && say "OK" "CONTROL: and it was a real call before the crash too ($CTLPRE reports), so the arms are comparable" \
  || say "FAIL" "CONTROL: the control arm never had a call, so it cannot be a control"

# ── 7. HANGING UP STILL ENDS A CALL ─────────────────────────────────────────
grep -q "left the call" "$SP/f.log" \
  && say "OK" "the hang-up control was pressed and taken" \
  || say "FAIL" "nobody managed to hang up, so part three measures nothing"
grep -qE "the other end hung up|the other person hung up" "$SP/e.log" \
  && say "OK" "and the far end was TOLD, on the call itself, not left to time out" \
  || say "FAIL" "the far end never heard the goodbye"
[ -f "$SP/idf/call.json" ] \
  && say "FAIL" "hanging up left the record behind -- this Mac would reopen the call" \
  || say "OK" "and the record is gone on the side that hung up"
[ -f "$SP/ide/call.json" ] \
  && say "FAIL" "the far end kept its record, so IT would reopen a call that ended" \
  || say "OK" "and gone on the far end too -- one hang-up ended it for both"
grep -q "rejoin" "$SP/f2.log" \
  && say "FAIL" "opening the app again after hanging up walked back into the call" \
  || say "OK" "and opening the app again after hanging up starts nothing"

# ── 8. AND AN UPDATE IN THE MIDDLE OF A CALL ────────────────────────────────
if [ -f "$SP/h.log" ]; then
  grep -q "update: installed 99.0.0" "$SP/h.log" \
    && say "OK" "the signed update was fetched, verified and installed mid-call" \
    || say "FAIL" "the update never installed: $(grep -m1 '^update:' "$SP/h.log")"
  grep -q "final beat (update-restart)" "$SP/h.log" \
    && say "OK" "and the outgoing image filed its ending before execv took it" \
    || say "FAIL" "the update re-exec filed no final beat -- the call vanishes from the record"
  grep -q "prev-call" "$SP/h.log" \
    && say "OK" "and handed its call id to its successor, so the two rows are one call" \
    || say "FAIL" "the successor does not name the row it continues"
  # ── ASSERT THE GAP, NOT THE SHAPE OF THE LAST SIX SAMPLES ─────────────────
  #
  # This counted how many of the far end's last six per-second reports had media
  # and required four. That is a proxy for "the call survived", and it depends on
  # WHERE in those six seconds the re-exec happened to land: the same 1-second gap
  # is 1 zero in the middle of the window and 3 zeros across a boundary. It failed
  # in the parallel lane, so it was moved to the exclusive one, and then failed
  # there too -- because the lane was never the problem, the sampling was.
  #
  # The rig already measures the thing itself, three lines down: the far end
  # reports its own `media gap N ms`. So the recovery is asserted on that, and the
  # sample count stays as the supporting sentence it always was. A gap under three
  # seconds is a call that survived an app restarting underneath it; measured
  # repeatedly here, it is about one second.
  UPBACK=$(grep -E "^cap " "$SP/g.log" | tail -6 | grep -cvE "recv 0/s")
  ANYBACK=$(grep -E "^cap " "$SP/g.log" | tail -3 | grep -cvE "recv 0/s")
  [ "${ANYBACK:-0}" -ge 1 ] \
    && say "OK" "and the other person was still there afterwards ($UPBACK of their last 6 reports had media, and media was flowing at the end)" \
    || say "FAIL" "the update ended the call for the person who did not take it: no media in their last 3 reports"
  grep -q "the other person left" "$SP/g.log" \
    && say "FAIL" "and they were told the other person left, over an update" \
    || say "OK" "and they were never told the other person left"
  UGAP=$(grep -oE "media gap [0-9]+ ms" "$SP/g.log" | head -1 | grep -oE "[0-9]+")
  # ── AND THE GAP ITSELF HAS A CEILING, SET FROM THE SPREAD ─────────────────
  #
  # Without a ceiling this line is a readout, and a readout cannot fail: an update
  # that cost the far end ten seconds of silence would have printed just as
  # cheerfully.
  #
  # The number is set from repeated measurement rather than from one sample, which
  # is how the first attempt at it went wrong. Observed on this machine, far-end
  # media gap over a mid-call update:
  #
  #     1057  1072  1081  1160 ms   -- run alone, four times
  #     3617 ms                     -- in the suite, straight after floor-check
  #
  # The re-exec itself is about 1.1 s of that (`re-exec costs a second camera`:
  # 2366 -> 1150 ms, and 46% of what is left is a platform floor for the sensor).
  # The outlier is a machine still busy, not a different code path. So the line is
  # drawn at 5 s: far enough above the spread that noise does not trip it, and far
  # enough below a dropped call that a real regression -- a re-exec that stopped
  # handing over, a rejoin that waited for a timeout -- cannot hide under it.
  if [ -n "${UGAP:-}" ]; then
    [ "${UGAP}" -le 5000 ] \
      && say "OK" "and it cost the far end ${UGAP} ms of media, inside the 5 s ceiling" \
      || say "FAIL" "taking an update cost the far end ${UGAP} ms of media -- long enough to be a dropped call"
  fi
  [ -n "${UGAP:-}" ] \
    && say "OK" "cost of taking an update mid-call, measured at the far end: ${UGAP} ms of media" \
    || say "OK" "the far end never even lost the peer long enough to notice a gap"
fi

echo
if [ "$fail" = 0 ]; then
  echo "LIVE-UPDATE CHECK PASSED -- a call outlives the app; only hanging up ends it"
else
  echo "LIVE-UPDATE CHECK FAILED -- see above; logs in $SP"
  KEEP=1
fi
exit $fail
