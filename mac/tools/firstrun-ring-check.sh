#!/bin/bash
# ── CAN A BRAND-NEW USER BE RUNG? ───────────────────────────────────────────
#
# Claiming a handle is a network round trip, and on a first install it is
# SEVERAL -- the obvious names are taken and it walks down the list, which took
# 5-8 seconds every time it was measured here. The doorbell used to be started by
# a single `if Identity.claimed` in top-level code that runs long before any of
# that finishes, so on a fresh install it read false and the poll thread never
# started. You claim a name, you tell somebody, and you cannot be rung until you
# quit and reopen Kin. First run is exactly when a person tries this.
#
# Both launches are checked, because either alone is passable by a broken build:
#   fresh   -- the handle is won WHILE running, so the late edge must fire
#   second  -- the handle is on disk, so the early edge must fire
#
# Windowed on purpose. `Identity.onClaimed` is delivered on the main queue, so
# without a run loop it cannot fire at all -- a headless run of this test reports
# a failure that is its own, not the app's (`blind-instruments-report-negatives`).
#
# ── AND DOES A BRAND-NEW USER GET A NAME AT ALL? ────────────────────────────
#
# Parts 4 to 9 were added after this Mac produced, on a real first install:
#
#     identity: new install, asking for @kinrig74230
#     identity: @kinrig74230 -> 429 {"error":"rate"}
#
# ...and then nothing, for the rest of the launch. Nobody could call that person
# and the app never said so. Those parts do not touch room.tokkah.com: they point
# `TK_KIN_BASE` at a stub on 127.0.0.1 that answers registrations from a script,
# so a 429, a 403 and a dead socket are all reproducible on demand and none of
# them is produced by hammering the real server -- which is both rude and the
# behaviour a 429 exists to stop.
#
# ── AND WHY THIS FILE STOPPED GUESSING ──────────────────────────────────────
#
# Part 1 used to end at "SKIPPED: no handle was claimed (offline?)" and exit 0.
# The log it had just read said `429 {"error":"rate"}`. Offline was a GUESS, the
# guess was wrong, and it was wrong for a while -- the skip is how the defect
# above stayed invisible. A rig may not invent a cause it can read: `claimStatus`
# below reads the last thing the server actually said and every verdict names it.
set -u
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# This used to `pkill -f "$TK"`, and `pkill -f` takes a REGEX: in a path like
# `./.build/debug/tk` every `.` matches any character, so the pattern also matched
# `/Users/.../worktrees/agent-XXXX/mac/.build/debug/tk`. It was reaping another
# agent's processes in another checkout and corrupting their measurements from the
# outside -- the exact thing lane isolation is supposed to prevent.
#
# PIDs, therefore. A rig may only end processes it started.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
# ── AND `wait` WITH NO ARGUMENTS IS NOT "wait for those" ─────────────────────
#
# It waits for EVERY background job of this shell. That was harmless while the
# only jobs were the ones `spawn` had just killed; the moment this file grew a
# stub server that is supposed to outlive a reap, the bare `wait` sat on the
# stub's pid and the whole rig hung after part 9 -- forever, with no output and
# nothing wrong with the app. Named pids only, here as everywhere else.
reap() {
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  for p in $PIDS; do wait "$p" 2>/dev/null; done
  PIDS=""
}
STUB_PID=""
# `disown` so bash does not print "Killed: 9" over the verdicts when it reaps it.
stub_stop() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
}
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/firstrun-ring.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; stub_stop; rm -rf "$SP"' EXIT

# An isolated identity dir AND a rig handle, so this never touches the handle the
# person at this Mac actually uses, and never squats a real-looking name.
export TK_KIN_DIR="$SP/kin"
H="kinrig$$"
ARGS="--window --video off --mute --no-telemetry --no-update --no-relocate --no-subtitles"
bad=0
# 8360-8379 is this lane's band. They used to be 745x, which belongs to nobody in
# particular and therefore to everybody: three other agents are running rigs on
# this Mac right now.
P1=8360; P2=8361; P3=8362; P4=8363; P5=8364
STUB_PORT=8367

say_ok()    { echo "   ok   $*"; }
say_wrong() { echo "  WRONG $*"; bad=1; }
# ── A SKIP IS A THIRD OUTCOME AND IT HAS TO EARN ITS PLACE ──────────────────
#
# This rig has reported all three verdicts for the same underlying condition on
# the same day: WRONG ("a fresh install cannot place a call at all") under a
# machine fault, SKIPPED ("offline?") under a 429, and PASSED. A skip may only be
# used for something OUTSIDE the thing under test, and it must say what it read.
say_skip()  { echo "  SKIP  $*"; }

# What the server actually said about the handle, read out of the app's own log.
# Never a guess: prints `won`, `429`, `403`, `http NNN`, `no-answer`, or `silent`
# when the app never even asked.
claimStatus() {
  if grep -qE '^identity: you are @' "$1"; then echo "won"; return; fi
  local last
  last="$(grep -E '^identity: @[a-z0-9]+ -> ' "$1" | tail -1)"
  if [ -z "$last" ]; then echo "silent"; return; fi
  case "$last" in
    *"-> no answer"*) echo "no-answer";;
    *"-> 429"*) echo "429";;
    *"-> 403"*) echo "403";;
    *) echo "http $(echo "$last" | sed -E 's/.*-> ([0-9]+).*/\1/')";;
  esac
}

run() { # log, port, extra args, seconds
  spawn "$TK" $ARGS --room "frcheck$$" --listen "$2" $3 > "$1" 2>&1
  perl -e "select undef,undef,undef,$4"
  reap; perl -e 'select undef,undef,undef,0.4'
}

# ── THE ONLY PARTS THAT NEED room.tokkah.com ───────────────────────────────
#
# Parts 1-3 cost 30 s of real network before anything else can run, and parts
# 4-10 need no network at all. `FR_SKIP_LIVE=1` runs the offline half on its own:
# a rig you have to wait half a minute to iterate on is a rig you stop iterating
# on. Never set in a full run -- the live half is the one that proves the fix
# against the server that produced the defect.
if [ "${FR_SKIP_LIVE:-0}" = 1 ]; then
  say_skip "parts 1-3: FR_SKIP_LIVE=1 -- the live-server half was not run"
else
echo "── part 1-3: the doorbell starts when the handle does (real server) ──"
run "$SP/a.log" "$P1" "--handle $H" 20
CLAIM="$(grep -n 'identity: you are' "$SP/a.log" | head -1 | cut -d: -f1)"
LISTEN="$(grep -n 'ring: listening' "$SP/a.log" | head -1 | cut -d: -f1)"
if [ -z "$CLAIM" ]; then
  # Named, not guessed. `429` here is the server throttling a real claim and says
  # nothing about this build; `silent` means the app never asked at all, which is
  # a defect and not a reason to skip.
  ST="$(claimStatus "$SP/a.log")"
  case "$ST" in
    silent) say_wrong "part 1: the app never asked the server for a handle at all";;
    *) say_skip "part 1-3: no handle -- the server said '$ST'. Needs room.tokkah.com."
       # And it did not have to be silent about it either. A 429 must leave the
       # app still trying; parts 4-9 prove that offline, so this is only a skip.
       ;;
  esac
else
  if [ -n "$LISTEN" ] && [ "$LISTEN" -gt "$CLAIM" ]; then
    say_ok "fresh install: doorbell starts when the handle is won (line $CLAIM -> $LISTEN)"
  else
    say_wrong "fresh install: handle won at line $CLAIM, doorbell never started"
  fi

  run "$SP/b.log" "$P2" "" 9
  if grep -q 'ring: listening' "$SP/b.log"; then
    say_ok "second launch: doorbell starts from the handle on disk"
  else
    say_wrong "second launch: a handle was on disk and the doorbell still did not start"
  fi
  # One thread, not two. Both edges fire on a second launch if the latch is wrong,
  # and two pollers on one mailbox take turns losing rings to each other.
  N="$(grep -c 'ring: listening' "$SP/b.log")"
  if [ "$N" = 1 ]; then say_ok "and exactly one poll thread ($N)"
  else say_wrong "$N doorbell threads -- they will steal rings from each other"; fi

  # ── AND CAN A BRAND-NEW USER PLACE ONE? ───────────────────────────────────
  #
  # The mirror of the bug above, found while measuring ring latency on production.
  # `Identity.ring` refused outright unless a handle was already claimed, and a
  # first install spends 5-8 seconds walking @devesh, @deveshp, @devesh2 ...
  # before it owns one. So: launch Kin, type a friend's name, press call -- and
  # the first thing the app ever does is fail. A one-shot read of a value that
  # arrives later, exactly like the doorbell above it.
  #
  # Inside the else, because it is the same precondition as parts 1-3 and used to
  # be outside it: when the server refused the claim this printed WRONG "a fresh
  # install cannot place a call at all" -- a real-sounding product defect
  # manufactured entirely by a throttled test.
  export TK_KIN_DIR="$SP/kin-caller"
  rm -rf "$TK_KIN_DIR"
  # `--mute` here too, and not because this line plays call audio. A ring is a
  # SOUND, and it is the one sound `--mute` was found not to be covering: rigs
  # rang out loud at the person sitting in front of this Mac. Every launch in
  # this file carries it through $ARGS; this one was assembled by hand and did
  # not, which is exactly how the gap gets back in.
  if "$TK" --mute --handle "kinrigcall$$" --ring-only "kinrig-nobody-$$" > "$SP/c.log" 2>&1; then
    : # a ring to a handle nobody owns should NOT succeed
  fi
  if grep -q "this Mac has no handle yet" "$SP/c.log"; then
    say_wrong "a fresh install cannot place a call at all (claim said: $(claimStatus "$SP/c.log"))"
  else
    say_ok "a fresh install gets a name before it needs one"
  fi
  echo "── part 3b: a 429 from the REAL server does not end the claim ──"
  # ── THE ONE THING THE STUB BELOW CANNOT DO ────────────────────────────────
  #
  # Parts 4-10 prove the retry against a stub, which is deterministic and free
  # but is not room.tokkah.com. This arm is: the first two attempts are treated
  # as a 429 before the request is even built, and the THIRD is a real
  # registration against production that must still win the name. So the recovery
  # path is exercised end to end against the server that produced the defect,
  # without asking it repeatedly until it refuses -- which is rude, and is the
  # behaviour a 429 exists to stop.
  #
  # A build that does not understand `TK_CLAIM_FORCE_STATUS` ignores it silently
  # and claims on the first try, so the count of forced lines is checked and not
  # only the outcome: `silent-no-op-flags`, where three A/Bs compared an arm
  # against itself.
  rm -rf "$SP/kin-forced"
  env TK_KIN_DIR="$SP/kin-forced" TK_CLAIM_FORCE_STATUS=429 TK_CLAIM_FORCE_TIMES=2 \
      TK_CLAIM_FORCE_RETRY_MS=200 \
      "$TK" --mute --no-telemetry --claim --handle "kinrigg$$" > "$SP/r0.log" 2>&1
  FORCED="$(grep -c 'forced,' "$SP/r0.log")"
  if [ "$FORCED" = 0 ]; then
    say_wrong "TK_CLAIM_FORCE_STATUS did nothing -- this build does not understand it"
  elif grep -q "claimed=true" "$SP/r0.log"; then
    say_ok "two forced 429s, then a real registration won the name ($FORCED forced)"
  else
    say_wrong "forced $FORCED 429s and the real claim never recovered:"\
              "the server said '$(claimStatus "$SP/r0.log")'"
  fi

  export TK_KIN_DIR="$SP/kin"
fi
fi

# ══ THE CLAIM LADDER, OFFLINE AND DETERMINISTIC ═════════════════════════════
#
# A stub that answers /api/kin/<h>/register from a script, so every arm below is
# the same on a fast network, a slow one and no network at all. It records one
# line per request -- the handle asked for and the status given -- which is the
# only place "did it ask for the SAME name again" is observable.
cat > "$SP/stub.cjs" <<'STUB'
// argv: port, script, request-log.  script is comma-separated `code[:retryMs]`,
// consumed one per registration; the LAST entry repeats for ever.
const http = require('http'), fs = require('fs');
const [port, script, logPath] = process.argv.slice(2);
const seq = script.split(',');
let n = 0;
http.createServer((req, res) => {
  const m = req.url.match(/^\/api\/kin\/([a-z0-9]+)\/register/);
  req.on('data', () => {});
  req.on('end', () => {
    if (!m) { res.writeHead(404, {'content-type':'application/json'}); res.end('{}'); return; }
    const [codeS, msS] = seq[Math.min(n, seq.length - 1)].split(':');
    n++;
    const code = Number(codeS);
    fs.appendFileSync(logPath, `${m[1]} ${code}\n`);
    const body = code === 429 ? { error: 'rate', retryMs: Number(msS || 0) }
               : code === 403 ? { error: 'taken' }
               : code === 200 ? { ok: true } : {};
    res.writeHead(code, {'content-type':'application/json'});
    res.end(JSON.stringify(body));
  });
}).listen(Number(port), '127.0.0.1', () => console.log('listening'));
STUB

stub_start() { # script
  stub_stop
  : > "$SP/stub.req"
  node "$SP/stub.cjs" "$STUB_PORT" "$1" "$SP/stub.req" > "$SP/stub.out" 2>&1 &
  STUB_PID=$!
  disown "$STUB_PID" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 50 ]; do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$STUB_PORT/up" && return 0
    perl -e 'select undef,undef,undef,0.1'; i=$((i+1))
  done
  echo "  stub never came up on $STUB_PORT"; return 1
}
# Every handle the stub was asked for, in order; and how many distinct ones.
asked()   { cut -d' ' -f1 "$SP/stub.req" | tr '\n' ' '; }
askedN()  { wc -l < "$SP/stub.req" | tr -d ' '; }
distinct(){ cut -d' ' -f1 "$SP/stub.req" | sort -u | wc -l | tr -d ' '; }
# The first back-off the app announced, in ms. The only place an honoured server
# hint is observable -- without it "we backed off correctly" and "we slept for our
# own reasons" are the same silence.
firstWait() {
  grep -E 'asking again in [0-9]+ ms' "$1" | head -1 | sed -E 's/.*asking again in ([0-9]+) ms.*/\1/'
}
export TK_KIN_BASE="http://127.0.0.1:$STUB_PORT"

claimRun() { # log, script, extra args, [env assignments...]
  local log="$1" script="$2" extra="$3"; shift 3
  rm -rf "$SP/kin-claim"; export TK_KIN_DIR="$SP/kin-claim"
  stub_start "$script" || return 1
  env "$@" "$TK" --mute --no-telemetry --claim $extra > "$log" 2>&1
  stub_stop
}

echo "── part 4: a 429 must not end the claim ──"
# The defect, exactly. Before this change the first 429 returned from `claim()`
# and that install had no handle for the rest of its life.
claimRun "$SP/r1.log" "429:900,429:0,200" "--handle kinrigA$$"
if grep -q "claimed=true" "$SP/r1.log" && [ "$(askedN)" = 3 ] && [ "$(distinct)" = 1 ]; then
  say_ok "429, 429, then 200: the same name asked 3 times and won (asked: $(asked))"
else
  say_wrong "429 ended the claim -- asked $(askedN) time(s) for $(distinct) name(s): $(asked)"
fi
# ── AND THE OVERRIDE HAS TO HAVE DONE SOMETHING ────────────────────────────
#
# Run these arms against a build from before this change and `TK_CLAIM_*` means
# nothing, quietly, and the stub simply answers whatever it likes. The count above
# is what stops that passing: one request is a build that gave up.
if [ "$(askedN)" -lt 2 ]; then
  say_wrong "part 4 never got past the first attempt -- this build does not retry at all"
fi

echo "── part 5: the server's own retry hint is honoured, and only when it is bigger ──"
# ── CALIBRATING THE RULER ─────────────────────────────────────────────────
#
# Two inputs that MUST rank differently, or the number being read proves nothing.
# Our own back-off at the first ask is 0.25 x 2 x jitter(0.75..1.25) = 375..625 ms.
#   retryMs 1500 -> the hint wins, and the wait cannot be under 1500
#   retryMs 0    -> our own back-off wins, and the wait cannot be over 700
W_HINT="$(firstWait "$SP/r1.log")"       # part 4's first 429 carried retryMs 900
claimRun "$SP/r2.log" "429:0,200" "--handle kinrigB$$"
W_NONE="$(firstWait "$SP/r2.log")"
if [ -n "$W_HINT" ] && [ -n "$W_NONE" ] && [ "$W_HINT" -ge 900 ] && [ "$W_NONE" -le 700 ]; then
  say_ok "hinted 900 ms -> waited ${W_HINT} ms; unhinted -> waited ${W_NONE} ms"
else
  say_wrong "back-off does not follow the hint: hinted=${W_HINT:--} unhinted=${W_NONE:--}"
fi

echo "── part 6: a 403 still moves DOWN the ladder ──"
# The control that must rank the other way. "Retry instead of giving up" is a
# short step from "retry everything", which would ask one refused name for ever
# and never reach the next rung. No --handle, so the real ladder is walked -- at
# the stub, so no plausible name is squatted on the real server.
claimRun "$SP/r3.log" "403,200" ""
if grep -q "claimed=true" "$SP/r3.log" && [ "$(distinct)" = 2 ] && [ "$(askedN)" = 2 ]; then
  say_ok "403 then 200: two different names, in order (asked: $(asked))"
else
  say_wrong "403 did not advance the ladder -- asked $(askedN) time(s), $(distinct) name(s): $(asked)"
fi

echo "── part 7: a 429 must never advance the ladder, or say the names are taken ──"
# The other half of part 6, and the reason the comment above `claim()` was right
# all along: taking the next name because the network hiccuped silently renames
# somebody who already owns `devesh`.
# 3500 ms, and the number is measured rather than picked. The back-off is
# 0.25 x 2^k x jitter(0.75..1.25), so the third ask lands at 1.9 s at the latest
# and the fourth at 4.4 s at the earliest-plus-worst -- a budget of 1500 was tried
# first and produced exactly TWO asks every time, failing a ">= 3" assertion that
# the app could never have satisfied. An assertion the code cannot reach is a rig
# bug wearing a defect's clothes.
claimRun "$SP/r4.log" "429:150" "" TK_CLAIM_BUDGET_MS=3500
if [ "$(distinct)" = 1 ] && [ "$(askedN)" -ge 3 ]; then
  say_ok "refused $(askedN) times, never took a different name (asked: $(asked))"
else
  say_wrong "a run of 429s walked the ladder: $(askedN) ask(s), $(distinct) name(s): $(asked)"
fi
if grep -q "every name this Mac suggests is taken" "$SP/r4.log"; then
  say_wrong "and it blamed the names -- that sentence sends the person to rename for nothing"
else
  say_ok "and it did not blame the names"
fi

echo "── part 8: a dead network is not 'try again next launch' ──"
# `attempt` returning nil used to `return`, with the comment "no network: try next
# launch". A laptop opened before Wi-Fi associates is the ORDINARY case, and that
# Mac then ran for hours with no handle and no second attempt. Nothing is
# listening on the stub port here: this is a real connection refused.
stub_stop
rm -rf "$SP/kin-claim"; export TK_KIN_DIR="$SP/kin-claim"
env TK_CLAIM_BUDGET_MS=1200 "$TK" --mute --no-telemetry --claim --handle "kinrigD$$" \
  > "$SP/r5.log" 2>&1
NOANS="$(grep -c -- '-> no answer' "$SP/r5.log")"
if [ "$NOANS" -ge 2 ]; then
  say_ok "no network: asked $NOANS times inside one launch, not once"
else
  say_wrong "no network: asked $NOANS time(s) -- it is waiting for the next launch"
fi

echo "── part 9: it keeps trying for the life of the process ──"
# ── THE DUTY LOOP ─────────────────────────────────────────────────────────
#
# A Mac that could not get a name at 9am must have one by 9:05 without the person
# restarting anything. `start()` used to spawn exactly one `claim()`.
#
# The budget is set below one back-off, so the FIRST pass cannot possibly win --
# the 200 is only reachable by a second pass, which is the thing being proved.
# `TK_CLAIM_RETRY_MS` compresses the 5 s duty cadence to 700 ms; every production
# cadence in this app has a rig override for exactly this reason.
rm -rf "$SP/kin-claim"; export TK_KIN_DIR="$SP/kin-claim"
stub_start "429:400,429:400,429:400,200" || bad=1
spawn env TK_CLAIM_BUDGET_MS=900 TK_CLAIM_RETRY_MS=700 TK_NO_RAISE=1 \
  "$TK" $ARGS --room "frdrill$$" --listen "$P4" --handle "kinrigE$$" > "$SP/r6.log" 2>&1
perl -e 'select undef,undef,undef,6'
reap; stub_stop
GAVEUP="$(grep -n 'out of time on @' "$SP/r6.log" | head -1 | cut -d: -f1)"
WON="$(grep -n 'identity: you are @' "$SP/r6.log" | head -1 | cut -d: -f1)"
if [ -n "$GAVEUP" ] && [ -n "$WON" ] && [ "$WON" -gt "$GAVEUP" ]; then
  say_ok "a pass ran out at line $GAVEUP and a LATER pass won the name at line $WON"
elif [ -n "$WON" ] && [ -z "$GAVEUP" ]; then
  # Not a pass. The whole point is that the second pass is what won it, and a
  # first pass that squeaked in proves only that the stub was generous.
  say_skip "part 9: the first pass won it -- the budget did not bite, nothing proved"
else
  say_wrong "no second pass: gave up at line ${GAVEUP:--}, won at line ${WON:--}"
fi

echo "── part 10: and the person can find out why, inside the app ──"
# ── THE SENTENCE, ON THE SCREEN ───────────────────────────────────────────
#
# Until now the People panel said "Your name on Kin isn't set up yet." and
# nothing else -- no reason, and the same words for a dead network, a busy
# server and a name somebody else owns. Only the third is the person's to fix.
#
# Read out of the app's own state dump. `hints=` is in `describeTree` because a
# SheetHint is not a SheetRow, so every sentence in that panel was invisible to
# every rig here -- the argument that put `warn=` there. The stub never answers
# 200 in this arm, so the panel is genuinely nameless when it is photographed.
rm -rf "$SP/kin-claim"; export TK_KIN_DIR="$SP/kin-claim"
stub_start "429:400" || bad=1
spawn env TK_CLAIM_BUDGET_MS=20000 TK_NO_RAISE=1 \
  "$TK" $ARGS --room "frsheet$$" --listen "$P5" --handle "kinrigF$$" \
  --press "people,?" --press-after 2.5 > "$SP/r7.log" 2>&1
perl -e 'select undef,undef,undef,6'
reap; stub_stop
# ── AND IT IS ON THE SECOND LINE ───────────────────────────────────────────
#
# `describeTree` puts the sheet on a line of its own, so a grep for `audit state`
# reads the line that does NOT contain the sheet, the substitution matches
# nothing, `sed` passes the input through unchanged, and the whole state dump
# arrives here dressed as the panel's hint text. That is a rig reporting the app
# has no reason on screen while the reason is one line further down. Matched on
# the field itself, and extracted with `-o` so a line that does not contain it
# yields an empty string rather than itself.
HINTS="$(grep -oE 'hints=\[[^]]*\]' "$SP/r7.log" | head -1 | sed -E 's/^hints=\[(.*)\]$/\1/')"
PAGE="$(grep -oE 'sheet=[a-z]+' "$SP/r7.log" | head -1)"
[ "$PAGE" = "sheet=people" ] || say_wrong "the People page never opened ($PAGE) -- part 10 proves nothing"
case "$HINTS" in
  *"waiting its turn"*|*"reach the internet"*|*"set up your name just now"*)
    say_ok "the People panel said why: \"$HINTS\"";;
  *"set up yet"*)
    say_wrong "the People panel still gives no reason: \"$HINTS\"";;
  "")
    # Two very different things, and this rig has been punished before for
    # collapsing them: a panel that carries no sentences at all, and a build whose
    # state dump has no `hints=` field to read (every build before this change).
    # Say which, rather than inventing "the press never ran".
    if grep -q 'audit state' "$SP/r7.log"; then
      say_wrong "the state dump has no hints= field -- this build cannot show a reason"
    else
      say_wrong "no state dump at all -- the press never ran, so nothing was proved"
    fi;;
  *)
    say_wrong "no reason on screen -- hints=[$HINTS]";;
esac

echo "── part 11: pressing Call BETWEEN two attempts must not fail ──"
# ── THE GAP THE DUTY LOOP OPENED ────────────────────────────────────────────
#
# `ring()` waits up to 6 s for a claim in flight, and that wait used to end the
# moment `claiming` went false, on the reading that a finished ladder which had
# not won was final. Adding the duty loop made that reading wrong: `claiming` is
# now false BETWEEN passes as well as after the last one, so a person pressing
# Call while the app was mid-back-off got "this Mac has no handle yet" from an
# app that was still working on the answer and would have had it moments later.
#
# Made deterministic rather than raced: a budget too small to finish one pass, a
# retry floor far enough away that the duty loop cannot rescue it, and a stub
# that says 429 once and then yes. The wait itself has to drive the second pass.
#
# The ring is EXPECTED to fail here -- the stub answers /register and 404s the
# doorbell -- so the assertion is on the one sentence that distinguishes "no
# name" from "no mailbox". A build with the old early-out prints it; this one
# must not.
rm -rf "$SP/kin-gap"
stub_start "429:2000,200" || say_wrong "part 11: the stub never came up"
env TK_KIN_DIR="$SP/kin-gap" TK_CLAIM_BUDGET_MS=300 TK_CLAIM_RETRY_MS=30000 \
    "$TK" --mute --no-telemetry --handle "kinriggap$$" \
          --ring-only "kinrig-nobody-$$" > "$SP/r8.log" 2>&1
stub_stop
GAPN="$(askedN)"
if grep -q "this Mac has no handle yet" "$SP/r8.log"; then
  say_wrong "Call refused during the gap between attempts (asked $GAPN time(s): $(asked))"
elif [ "$GAPN" -lt 2 ]; then
  # One attempt means the first pass won outright and the gap was never entered,
  # so a pass here proves nothing -- the same trap part 9 guards against.
  say_skip "part 11: only $GAPN attempt(s) -- the budget did not bite, nothing proved"
else
  say_ok "the wait drove a second attempt and got the name ($GAPN asks: $(asked))"
fi

[ "$bad" = 0 ] && echo "  FIRST-RUN RING CHECK PASSED -- a new user gets a name and is reachable without restarting Kin" \
                || echo "  FIRST-RUN RING CHECK FAILED"
exit $bad
