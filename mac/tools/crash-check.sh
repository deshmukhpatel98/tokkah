#!/bin/bash
# ── DOES A CRASH ON SOMEBODY ELSE'S MAC REACH US? ────────────────────────────
#
# It did not. Every crash this app has ever had on a machine that is not this one
# has been invisible: macOS writes an .ips file into a folder nobody opens, and
# the person shrugs and launches it again. There is no App Store feed to read,
# and Apple's own "share with developers" goes to Apple.
#
# That mattered more from the release that made the always-on watcher update
# itself unattended, because a build that crashes on launch now spreads to every
# Mac with nobody watching it go.
#
# THREE THINGS ARE BEING PROVED, AND THEY ARE NOT THE SAME THING:
#
#   1. THE PARSER. Given a crash report, does the right explanation come out --
#      the exception, the signal, the stack, and the version that DIED rather
#      than the version doing the reporting? Proved by replaying real .ips files
#      this Mac already had, from three different names this app has run under.
#   2. THE DETECTION. Does a crash that happens right now get found at all?
#      Proved by killing a real `tk` with SIGABRT and reading what the next
#      launch sends. A file placed in a directory can never prove this: it says
#      nothing about whether macOS's folder is the one being read, whether the
#      report arrives before the sweep runs, or whether the app recognises its
#      own freshly-written report.
#   3. THE DEATH WITH NO REPORT. A hang somebody force-quits, a SIGKILL, a power
#      cut -- macOS writes nothing at all for any of them, and "unexplained death
#      is a bug" is a law in this project. Proved with SIGKILL.
#
# AND EVERY ONE OF THEM HAS AN ARM THAT RANKS THE OTHER WAY. "No crashes found"
# and "the finder is broken" return the same answer otherwise, and that exact
# class of blind instrument has produced three false root causes here in one day.
# So: another app's crash report in the same folder must NOT be sent; a clean
# exit must NOT be reported as a death; a crash already sent must NOT be sent
# again, while a DIFFERENT one still must be.
set -u
# Ring windows and the app's own activation do not get to interrupt whoever is
# using this Mac while the rig runs.
export TK_NO_RAISE=1
# These rigs must never claim a handle on the real server. Sibling of TK_KIN_DIR.
export TK_NO_IDENTITY=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/crash-check.$$"
mkdir -p "$SP"
# ── ITS OWN EVERYTHING ──────────────────────────────────────────────────────
#
# TK_KIN_DIR because `.applicationSupportDirectory` resolves through the user
# record and not $HOME, so a rig without it reads and writes the REAL install's
# state -- and the state this rig writes is "which crashes have already been
# reported", which is exactly the file you least want to corrupt on somebody's
# actual machine.
#
# TK_CRASH_DIR is the same idea for the input side, and it is deliberately NOT
# set for part two: that part has to read the real folder, because proving that
# a real crash is found means reading the folder macOS actually writes to.
export TK_KIN_DIR="$SP/id"
mkdir -p "$SP/id"
# The grace before a run that vanished is reported. It exists so a crash report
# has time to be written before its absence is called evidence; in production it
# is 45 seconds and here there is nothing to wait for.
export TK_CRASH_GRACE_S=1
[ -x "$TK" ] || { echo "CRASH CHECK COULD NOT RUN -- no tk at $TK, swift build first"; exit 2; }
command -v node >/dev/null 2>&1 \
  || { echo "CRASH CHECK COULD NOT RUN -- no node, and the sink needs it"; exit 2; }
command -v python3 >/dev/null 2>&1 \
  || { echo "CRASH CHECK COULD NOT RUN -- no python3 to read the sink's output"; exit 2; }
REAL_REPORTS="$HOME/Library/Logs/DiagnosticReports"
[ -d "$REAL_REPORTS" ] \
  || { echo "CRASH CHECK COULD NOT RUN -- no $REAL_REPORTS on this Mac"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# ── THE SINK ────────────────────────────────────────────────────────────────
#
# A local stand-in for room.tokkah.com on 8104. Nothing in this rig may reach the
# real server: it would file crashes from a machine that is being deliberately
# killed once a second into the feed a human reads to decide whether a release is
# safe.
SINK="$SP/sink"
spawn node "$HERE/crash-sink.mjs" --port 8104 --out "$SINK" > "$SP/sink.log" 2>&1
perl -e 'select undef,undef,undef,1'
grep -q "sink: listening" "$SP/sink.log" \
  || { echo "CRASH CHECK COULD NOT RUN -- the sink never came up:"; sed 's/^/  /' "$SP/sink.log"; exit 2; }
ENDPOINT="http://127.0.0.1:8104/api/mac/beat"

# One tk, one log. It joins a room nobody else is in and waits, which is the
# cheapest way to have a real process that is really running.
# $1 log name, $2 crash dir ("" for the machine's real one), and optionally
# $3 room / $4 listen port / $5 peer port, which only the connected pair needs.
# The sink is TCP on 8104 and the media is UDP, so 8103 and 8104 are both free
# for a pair without anything colliding.
start_tk() {
  local room="${3:-crash$$$1}" lis="${4:-8103}" pr="${5:-8199}" bin="${TKBIN:-$TK}"
  if [ -n "$2" ]; then
    TK_CRASH_DIR="$2" spawn "$bin" --room "$room" --listen "$lis" --peer "127.0.0.1:$pr" \
      --video off --mute --no-update --no-relocate --no-rings --no-subtitles \
      --tel-endpoint "$ENDPOINT" > "$SP/$1.log" 2>&1
  else
    spawn "$bin" --room "$room" --listen "$lis" --peer "127.0.0.1:$pr" \
      --video off --mute --no-update --no-relocate --no-rings --no-subtitles \
      --tel-endpoint "$ENDPOINT" > "$SP/$1.log" 2>&1
  fi
  TKPID="$LAST_PID"
  # Wait for the run to be on the books rather than for a fixed number of
  # seconds: killing it before it has recorded itself would prove nothing, and a
  # sleep long enough to be safe is a sleep that makes this rig slow.
  for _ in $(seq 1 60); do
    grep -qa "^crash: this run is on the books" "$SP/$1.log" && return 0
    perl -e 'select undef,undef,undef,0.1'
  done
  return 1
}

# Every crash the sink has been given, as one JSON object per line, read with a
# little python because a crash record is nested and grep is not a JSON parser.
q() {  # $1 = python expression over `rows`
  python3 -c "
import json,sys
rows=[]
try:
    for line in open('$SINK.crash'):
        line=line.strip()
        if line: rows.append(json.loads(line))
except FileNotFoundError: pass
print($1)
" 2>/dev/null
}

# ── PART ONE: REAL CRASH REPORTS, REPLAYED ──────────────────────────────────
#
# Three of this app's own historical crashes and two other applications', in one
# folder, exactly as they sit in the real one. The app has been called `tk`,
# `tk_new`, `tkreal`, `Tokkah` and now `Kin`, and reports are named after the
# PROCESS -- so a matcher that knows only today's name misses every crash from an
# older build, which is precisely the population worth hearing from.
mkdir -p "$SP/replay"
copied=0
for pat in "Tokkah-" "tk-" "tk_new-" "tkreal-"; do
  for f in "$REAL_REPORTS"/$pat*.ips "$REAL_REPORTS"/Retired/$pat*.ips; do
    [ -f "$f" ] || continue
    cp "$f" "$SP/replay/" 2>/dev/null && copied=$((copied + 1))
    break
  done
done
# The negative arm's material: other applications' crashes, in the same folder,
# from the same week. Without these, "it sent two crashes" is equally consistent
# with a matcher that sends everything it can read.
others=0
for f in "$REAL_REPORTS"/Retired/*.ips; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in tk-*|tk_new-*|tkreal-*|Tokkah-*|Kin-*) continue ;; esac
  cp "$f" "$SP/replay/" 2>/dev/null && others=$((others + 1))
  [ "$others" -ge 4 ] && break
done
# A synthetic one, for the two things no real report on this Mac happens to
# carry: a path with a real account name still in it (macOS redacts some and not
# others), and a stack long enough to have to be cut down.
python3 - "$SP/replay/synthetic.ips" <<'PY'
import json, sys
head = {"app_name": "Kin", "app_version": "9.9.9", "bug_type": "309",
        "os_version": "macOS 27.0 (26A5421a)", "slice_uuid": "aaaaaaaa-0000-0000-0000-000000000001",
        "incident_id": "SYNTH-0000-0000-0000-000000000001", "name": "Kin",
        "timestamp": "2026-08-25 12:00:00.00 +0530"}
import os
home = os.path.expanduser("~")
body = {
  "procName": "Kin", "procPath": home + "/Applications/Kin.app/Contents/MacOS/Kin",
  "pid": 424242, "parentProc": "launchd", "modelCode": "Mac17,3",
  "bundleInfo": {"CFBundleIdentifier": "com.tokkah.tk", "CFBundleShortVersionString": "9.9.9"},
  "codeSigningID": "com.tokkah.tk",
  "crashReporterKey": "MUST-NOT-BE-SENT-0000",
  "userID": 501, "bootSessionUUID": "MUST-NOT-BE-SENT-1111",
  "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0"},
  "termination": {"namespace": "SIGNAL", "indicator": "Segmentation fault: 11",
                  "details": ["it happened under " + home + "/Library/Application Support/Kin"]},
  "asi": {"libsystem_c.dylib": ["synthetic parting words"]},
  "faultingThread": 0,
  "procStartAbsTime": 0, "procExitAbsTime": 0,
  "usedImages": [{"uuid": "aaaaaaaa-0000-0000-0000-000000000001", "name": "Kin",
                  "path": home + "/Applications/Kin.app/Contents/MacOS/Kin",
                  "CFBundleIdentifier": "com.tokkah.tk"}],
  # 120 frames with Swift-mangled-length symbols, and an ObjC backtrace on top.
  # Together they are past the size cap on purpose: this is the only file here
  # that reaches the code which has to shed weight, and shedding it by whole
  # fields rather than by truncating the JSON is the thing being proved.
  "lastExceptionBacktrace": [{"imageOffset": i, "symbolLocation": i, "imageIndex": 0,
                              "symbol": "objcThrowSite%03d" % i + "L" * 130} for i in range(12)],
  "threads": [{"triggered": True, "id": 1, "queue": "com.apple.main-thread",
               "threadState": {"x": [1] * 29},
               "frames": [{"imageOffset": i, "symbolLocation": i, "imageIndex": 0,
                           "symbol": "syntheticFrame%03d" % i + "W" * 130}
                          for i in range(120)]}],
}
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(head) + "\n" + json.dumps(body))
PY
start_tk replay "$SP/replay" || { echo "CRASH CHECK COULD NOT RUN -- tk never started for the replay"; sed -n '1,6p' "$SP/replay.log"; exit 2; }
perl -e 'select undef,undef,undef,5'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,3'
cp "$SINK.crash" "$SP/replay.crash" 2>/dev/null || : > "$SP/replay.crash"
REPLAY_ROWS="$(q 'len(rows)')"
REPLAY_KINDS="$(q '",".join(sorted(set(r["kind"] for r in rows)))')"
REPLAY_PROCS="$(q '",".join(sorted(set(r.get("proc","") for r in rows)))')"
REPLAY_WHERE="$(q '",".join(sorted(r.get("where","-") for r in rows))')"
REPLAY_SYNTH="$(q 'sum(1 for r in rows if r.get("incident","").startswith("SYNTH"))')"
REPLAY_LEAK="$(q 'sum(1 for r in rows if "MUST-NOT-BE-SENT" in json.dumps(r))')"
REPLAY_HOME="$(q 'sum(1 for r in rows if "'"$HOME"'" in json.dumps(r))')"
REPLAY_BIG="$(q 'max([len(json.dumps(r)) for r in rows] or [0])')"
REPLAY_DROPPED="$(q '",".join(sorted(set(d for r in rows for d in r.get("dropped",[]))))')"
REPLAY_CUT="$(q '",".join("%d of %d" % (len(r.get("frames",[])), r.get("frames_total",0)) for r in rows if r.get("frames_total",0) > 40)')"
REPLAY_CORE="$(q '",".join(sorted(k for k in ("exc","sig","app_version","where") if (([r for r in rows if r.get("incident","").startswith("SYNTH")]+[{}])[0]).get(k)))')"
REPLAY_VERSIONS="$(q '",".join(sorted(set(r.get("app_version","?") for r in rows)))')"
REPLAY_REPORTER="$(q '",".join(sorted(set(r.get("version","?") for r in rows)))')"

# ── PART TWO: THE SAME FOLDER AGAIN, AND ONE NEW FILE IN IT ─────────────────
#
# Dedup and its opposite in one launch. A second sweep of the same folder must
# send nothing -- and a folder with one NEW report in it must still send that
# one, or "sent nothing" is satisfied by a reporter that has simply stopped.
: > "$SINK.crash"
sed 's/SYNTH-0000-0000-0000-000000000001/SYNTH-0000-0000-0000-000000000002/' \
  "$SP/replay/synthetic.ips" > "$SP/replay/synthetic2.ips"
start_tk again "$SP/replay" || { echo "CRASH CHECK COULD NOT RUN -- tk never started for the second sweep"; exit 2; }
perl -e 'select undef,undef,undef,5'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,3'
AGAIN_ROWS="$(q 'len(rows)')"
AGAIN_IDS="$(q '",".join(sorted(r.get("incident","") for r in rows))')"

# ── PART THREE: A REAL CRASH, CAUSED ON PURPOSE ─────────────────────────────
#
# No TK_CRASH_DIR here, on purpose: this half has to read the folder macOS
# actually writes to, or it proves the parser again and nothing else. The state
# file is seeded with a sweep mark of "now" so the machine's own crash history is
# out of scope and the only thing this launch can find is the crash this rig
# caused.
: > "$SINK.crash"
rm -rf "$SP/id"; mkdir -p "$SP/id"
# ── A COPY UNDER A NAME NOTHING HAS CRASHED UNDER BEFORE ────────────────────
#
# Two reasons, and the first one is why this rig was intermittent. macOS
# THROTTLES crash reports: abort the same binary a few times in a row and
# ReportCrash stops writing them, so the arm that proves detection quietly
# stopped having anything to detect. A fresh name every run is a fresh subject.
#
# The second is a bonus that could not be bought any other way: this proves a
# REAL crash, from a process name no build has ever used, is still recognised as
# ours -- the ad-hoc signature travels inside the binary, so the copy is still
# identified by what it IS rather than by what it is called.
CRASHBIN="$SP/tkcrash$$"
cp "$TK" "$CRASHBIN" || { echo "CRASH CHECK COULD NOT RUN -- could not copy tk"; exit 2; }
TKBIN="$CRASHBIN" start_tk crashme "" \
  || { echo "CRASH CHECK COULD NOT RUN -- tk never started for the real crash"; exit 2; }
CRASHED_PID="$TKPID"
perl -e 'select undef,undef,undef,4'
# Narrowed to the last possible moment. Other agents run this app's rigs on this
# same Mac and kill their own processes; a sweep window opened before the launch
# can fill up with THEIR crash reports and push this one past the per-launch cap.
python3 -c "
import json,time
json.dump({'v':1,'sweptUntil':time.time(),'sent':[]}, open('$SP/id/crashes.json','w'))
"
# SIGABRT rather than a hidden --crash-now flag: nothing test-only ends up in the
# product, and an abort from outside lands wherever the program happens to be,
# which is more like a real crash than a fatal error placed on purpose.
kill -ABRT "$CRASHED_PID" 2>/dev/null
# ── WAIT FOR *THIS* REPORT, NOT FOR *A* REPORT ──────────────────────────────
#
# macOS writes it asynchronously, so this waits rather than sleeping. Matched on
# the pid INSIDE the file: matching on the filename matched other agents' crashed
# copies of this same app, so the rig went on to assert against a report that had
# not been written yet and blamed the feature for it.
for _ in $(seq 1 150); do
  python3 -c "
import glob,json,os,sys
D=os.path.expanduser('~/Library/Logs/DiagnosticReports')
for f in glob.glob(D+'/*.ips')+glob.glob(D+'/Retired/*.ips'):
    try:
        with open(f) as fh:
            fh.readline()
            if json.load(fh).get('pid') == $CRASHED_PID: sys.exit(0)
    except Exception: pass
sys.exit(1)
" && break
  perl -e 'select undef,undef,undef,0.2'
done
IPS_WRITTEN="$(python3 -c "
import glob,json,os
D=os.path.expanduser('~/Library/Logs/DiagnosticReports')
n=0
for f in glob.glob(D+'/*.ips')+glob.glob(D+'/Retired/*.ips'):
    try:
        with open(f) as fh:
            fh.readline()
            if json.load(fh).get('pid') == $CRASHED_PID: n+=1
    except Exception: pass
print(n)
")"
# THE ARM'S OWN PRECONDITION. If macOS declined to write a report there is
# nothing here to find, and every assertion below would be measuring the
# absence of a subject rather than the presence of a defect.
[ "${IPS_WRITTEN:-0}" -ge 1 ] || {
  echo "CRASH CHECK COULD NOT RUN -- macOS wrote no crash report for the process this"
  echo "  rig aborted (pid $CRASHED_PID, $CRASHBIN). ReportCrash throttles repeats, and"
  echo "  without a report there is nothing for the detection arm to detect."
  exit 2
}
start_tk after "" || { echo "CRASH CHECK COULD NOT RUN -- tk never started after the crash"; exit 2; }
perl -e 'select undef,undef,undef,6'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,3'
REAL_HIT="$(q 'sum(1 for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"' and r.get("kind")=="crash")')"
REAL_SIG="$(q '",".join(r.get("sig","?") for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"')')"
REAL_RAN="$(q '",".join(str(r.get("ran_ms","?")) for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"')')"
REAL_JOIN="$(q 'sum(1 for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"' and r.get("crashed_call"))')"
REAL_OURS="$(q '",".join(str(r.get("our_frames","?")) for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"')')"
REAL_PROC="$(q '",".join(r.get("proc","?") for r in rows if r.get("crashed_pid")=='"$CRASHED_PID"')')"
REAL_VANISHED="$(q 'sum(1 for r in rows if r.get("kind")=="vanished" and r.get("crashed_pid")=='"$CRASHED_PID"')')"

# ── PART FOUR: THE DEATH THAT LEAVES NO REPORT ──────────────────────────────
#
# SIGKILL. macOS writes nothing at all -- no .ips, no exception, no stack -- and
# this is the shape a hang somebody force-quits, a watchdog kill and a power cut
# all take. The only evidence that exists is that a run started and never filed
# an ending, and this app files one at every ending it controls.
: > "$SINK.crash"
mkdir -p "$SP/empty"
rm -rf "$SP/id"; mkdir -p "$SP/id"

# ── FIRST, THE ARM THAT MUST RANK THE OTHER WAY ─────────────────────────────
#
# Two copies that really find each other and really connect, and then end
# cleanly. Without this the whole part proves only that SOMETHING gets reported,
# which a reporter that files a death for every launch would also satisfy.
#
# A PAIR, and not one lone process, because of what this rig found the first time
# it ran: the SIGINT/SIGTERM handlers are installed at the very bottom of
# main.swift, BELOW the rendezvous -- so a copy still waiting for the other
# person has no handler yet, dies on the default action, and files no ending.
# That is a true unexplained death and this reporter is right to file it; it also
# means a lone waiting process can never be the clean control, and a control that
# cannot come out clean is not a control.
start_tk cleana "$SP/empty" "crash$$pair" 8103 8104 \
  || { echo "CRASH CHECK COULD NOT RUN -- the first half of the clean pair never started"; exit 2; }
CLEAN_A="$TKPID"
start_tk cleanb "$SP/empty" "crash$$pair" 8104 8103 \
  || { echo "CRASH CHECK COULD NOT RUN -- the second half of the clean pair never started"; exit 2; }
CLEAN_B="$TKPID"
for _ in $(seq 1 120); do
  grep -qa "connected via" "$SP/cleana.log" && break
  perl -e 'select undef,undef,undef,0.25'
done
perl -e 'select undef,undef,undef,2'
kill -TERM "$CLEAN_A" "$CLEAN_B" 2>/dev/null
perl -e 'select undef,undef,undef,3'

start_tk vanish "$SP/empty" || { echo "CRASH CHECK COULD NOT RUN -- tk never started to be killed"; exit 2; }
VANISH_PID="$TKPID"
perl -e 'select undef,undef,undef,3'
kill -9 "$VANISH_PID" 2>/dev/null
perl -e 'select undef,undef,undef,1'
# Two launches: the first STAMPS the death, the second reports it. That is the
# grace window doing its job -- a crash loop relaunches in under a second and the
# report macOS is still writing has to be allowed to arrive before its absence is
# called evidence.
start_tk notice "$SP/empty" || { echo "CRASH CHECK COULD NOT RUN -- tk never started to notice"; exit 2; }
perl -e 'select undef,undef,undef,3'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
NOTICE_ROWS="$(q 'len(rows)')"
start_tk report "$SP/empty" || { echo "CRASH CHECK COULD NOT RUN -- tk never started to report"; exit 2; }
perl -e 'select undef,undef,undef,4'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
VANISH_HIT="$(q 'sum(1 for r in rows if r.get("kind")=="vanished" and r.get("crashed_pid")=='"$VANISH_PID"')')"
VANISH_CALL="$(q 'sum(1 for r in rows if r.get("kind")=="vanished" and r.get("crashed_call"))')"
VANISH_WHY="$(q '(([r.get("why","") for r in rows if r.get("kind")=="vanished"]+[""])[0])')"
CLEAN_DEATHS="$(q 'sum(1 for r in rows if r.get("kind") in ("vanished","restart") and r.get("crashed_pid") in ('"$CLEAN_A"','"$CLEAN_B"'))')"

# ── PART FIVE: A SEND THAT FAILS IS NOT A CRASH THAT IS LOST ────────────────
#
# The mark that says "already sent" is written only after the server says it took
# it. So a launch whose network is down must send nothing AND mark nothing, and
# the next launch must deliver the same crash. Both halves: a reporter that
# marked optimistically passes the first and fails the second, and a reporter
# that never marks at all passes the second and fails part two above.
: > "$SINK.crash"
rm -rf "$SP/id"; mkdir -p "$SP/id"
touch "$SINK.fail"
mkdir -p "$SP/retry"
sed 's/SYNTH-0000-0000-0000-000000000001/RETRY-0000-0000-0000-000000000001/' \
  "$SP/replay/synthetic.ips" > "$SP/retry/synthetic.ips"
start_tk down "$SP/retry" || { echo "CRASH CHECK COULD NOT RUN -- tk never started with the sink down"; exit 2; }
perl -e 'select undef,undef,undef,5'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
DOWN_ROWS="$(q 'len(rows)')"
DOWN_REFUSED="$(wc -l < "$SINK.refused" 2>/dev/null | tr -d ' ')"
rm -f "$SINK.fail"
start_tk up "$SP/retry" || { echo "CRASH CHECK COULD NOT RUN -- tk never started with the sink back"; exit 2; }
perl -e 'select undef,undef,undef,5'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
UP_ROWS="$(q 'sum(1 for r in rows if r.get("incident","").startswith("RETRY"))')"

# ── PART SIX: THE PROCESS THAT IS ALWAYS RUNNING ────────────────────────────
#
# The one that matters most, and the one that had none of this. `--watch` is the
# login item: it lives from login to logout and it now downloads and installs a
# new Kin on its own, so a release that crashes reaches every Mac with nobody
# watching -- and `Watch.run` returns `Never`, which put the whole crash sweep
# several hundred lines below it out of reach. Nothing switched it off; it was
# underneath a function that does not come back, exactly like the updater that
# was found in that same block.
#
# ── WHAT THIS ARM IS CAREFUL ABOUT ─────────────────────────────────────────
#
# The resident claims a handle and polls the doorbell for it, and the handle it
# derives comes from the MACHINE NAME -- which on this Mac is the real one. A rig
# that let it do that would poll the user's own mailbox and could swallow a real
# incoming call. So an identity is written first: already claimed, so nothing
# asks the server for it, and named something nobody will ever ring.
: > "$SINK.crash"
mkdir -p "$SP/watchid" "$SP/watchreports"
sed 's/SYNTH-0000-0000-0000-000000000001/WATCH-0000-0000-0000-000000000001/' \
  "$SP/replay/synthetic.ips" > "$SP/watchreports/synthetic.ips"
python3 -c "
import base64, json, os, random
seed = base64.b64encode(bytes(random.getrandbits(8) for _ in range(32))).decode()
tok = ''.join(random.choice('0123456789abcdef') for _ in range(64))
json.dump({'seed': seed, 'tok': tok, 'handle': 'kinrig$$', 'claimed': True, 'quiet': True},
          open('$SP/watchid/identity.json', 'w'))
"
start_watch() {  # $1 = log name -> sets WATCH_PID
  TK_KIN_DIR="$SP/watchid" TK_CRASH_DIR="$SP/watchreports" \
  TK_WATCH_LABEL="com.tokkah.tk.crashrig$$" \
    spawn "$TK" --watch --no-update --tel-endpoint "$ENDPOINT" > "$SP/$1.log" 2>&1
  WATCH_PID="$LAST_PID"
  for _ in $(seq 1 100); do
    grep -qa "^crash: this run is on the books" "$SP/$1.log" && return 0
    perl -e 'select undef,undef,undef,0.15'
  done
  return 1
}
# (a) it sweeps at all, and (b) being stopped the way launchd stops it files an
# ending rather than looking like a death.
start_watch watch || { echo "CRASH CHECK COULD NOT RUN -- the watcher never opened its books"; sed -n '1,6p' "$SP/watch.log"; exit 2; }
WATCH_PID_TERM="$WATCH_PID"
perl -e 'select undef,undef,undef,4'
kill -TERM "$WATCH_PID_TERM" 2>/dev/null
perl -e 'select undef,undef,undef,2'
WATCH_ROWS="$(q 'sum(1 for r in rows if r.get("incident","").startswith("WATCH"))')"
# THE ARM THAT RANKS THE OTHER WAY, and it is the whole reason (b) means
# anything: a second watcher, killed outright. If the SIGTERM'd one is silent
# only because nothing about a watcher is ever reported, this one is silent too.
start_watch watchkill || { echo "CRASH CHECK COULD NOT RUN -- the second watcher never started"; exit 2; }
WATCH_PID_KILL="$WATCH_PID"
perl -e 'select undef,undef,undef,2'
kill -9 "$WATCH_PID_KILL" 2>/dev/null
perl -e 'select undef,undef,undef,2'
# Two ordinary launches over the same books: the first stamps the deaths, the
# second reports whichever of them is real.
mkdir -p "$SP/empty"
TK_KIN_DIR="$SP/watchid" start_tk wsweepa "$SP/empty" || { echo "CRASH CHECK COULD NOT RUN -- no sweep after the watchers"; exit 2; }
perl -e 'select undef,undef,undef,3'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
TK_KIN_DIR="$SP/watchid" start_tk wsweepb "$SP/empty" || { echo "CRASH CHECK COULD NOT RUN -- no second sweep after the watchers"; exit 2; }
perl -e 'select undef,undef,undef,4'
kill -TERM "$TKPID" 2>/dev/null
perl -e 'select undef,undef,undef,2'
WATCH_TERM_DEATH="$(q 'sum(1 for r in rows if r.get("kind") in ("vanished","restart") and r.get("crashed_pid")=='"$WATCH_PID_TERM"')')"
WATCH_KILL_DEATH="$(q 'sum(1 for r in rows if r.get("kind") in ("vanished","restart") and r.get("crashed_pid")=='"$WATCH_PID_KILL"')')"
reap

# ── PART SEVEN: WHAT IT COSTS WHEN NOTHING CRASHED ──────────────────────────
#
# The common case, by an enormous margin, is a machine with no new crash reports
# at all -- and this app treats launch as a measured budget. Timed to the `mic:`
# line, which the main thread prints just past the point where the sweep is
# started: if the sweep were on the main thread, or if it read files before
# handing off, this is where it would show.
#
# Two arms, and the loaded one is the STEADY STATE rather than a first run: a
# folder with everything in it, all of it already accounted for. That is what a
# real Mac looks like on its second launch and every launch after it.
#
# ── AND THE RIG'S OWN NOISE IS MEASURED BEFORE ANY OF IT IS BELIEVED ────────
#
# Two identical empty folders are timed alongside the loaded one. Whatever gap
# appears between those two is what this harness produces from nothing, and no
# claim about the loaded arm can be smaller than it. The arms are rotated round
# by round as well, because a machine that warms up (or that somebody starts
# using halfway through) hands the first arm measured a different number from the
# last one, and a fixed order books that as the effect.
#
# Down a pty, not a pipe: this app moves its own stderr into ~/Library/Logs/Kin
# whenever stderr is not a terminal and not a regular file, so reading its output
# through a pipe reads nothing at all -- which cost this rig an hour.
#
# A FRESH state directory before every single launch, so every launch in the
# loaded arm is a FIRST run: it reads all ten reports and posts what it can. That
# is the worst case rather than the common one, and the common one -- a folder
# whose reports are all already accounted for -- costs strictly less. It also
# keeps this part from measuring its own bookkeeping: with a shared directory
# each killed launch becomes a vanished run for the next one to report, and the
# arms would differ by how much of that had piled up rather than by the folder.
one() {  # $1 = crash dir -> milliseconds from exec to the microphone check
  rm -rf "$SP/cost-state"; mkdir -p "$SP/cost-state"
  TK_KIN_DIR="$SP/cost-state" TK_CRASH_DIR="$1" perl -MTime::HiRes=time -e '
    my $t0 = time;
    my $pid = open(my $fh, "-|", "script", "-q", "/dev/null", $ARGV[0],
      "--room", "costcheck" . $$, "--listen", "8103", "--peer", "127.0.0.1:8199",
      "--video", "off", "--mute", "--no-update", "--no-relocate", "--no-rings",
      "--no-subtitles", "--tel-endpoint", $ARGV[1]) or die;
    my $ms = -1;
    while (<$fh>) { if (/^mic: /) { $ms = (time - $t0) * 1000; last; } }
    kill "KILL", $pid; close($fh);
    printf "%.1f\n", $ms;
  ' -- "$TK" "$ENDPOINT"
}
# THE FLOOR, not the middle. A launch time is the work plus whatever else this
# Mac happened to be doing, and only the work is common to every sample -- so the
# smallest of a set is the closest thing to the launch with nothing in front of
# it. Same reasoning the region probe uses for round trips, and it matters here
# because several other agents are running builds and calls on this machine while
# this measures: with the median, an arm that got unlucky twice out of seven read
# 11 ms slower than an arm that did strictly more work.
lo() { echo "$1" | tr ' ' '\n' | grep -v '^$' | sort -n | head -1; }
mkdir -p "$SP/cost-empty" "$SP/cost-null"
E=""; L=""; N=""
for i in $(seq 1 9); do
  case $((i % 3)) in
    0) order="e l n" ;;
    1) order="l n e" ;;
    *) order="n e l" ;;
  esac
  for a in $order; do
    case "$a" in
      e) E="$E $(one "$SP/cost-empty")" ;;
      l) L="$L $(one "$SP/replay")" ;;
      n) N="$N $(one "$SP/cost-null")" ;;
    esac
    perl -e 'select undef,undef,undef,0.3'
  done
done
COST_EMPTY="$(lo "$E")"
COST_NULL="$(lo "$N")"
COST_LOADED="$(lo "$L")"
COST_FILES="$(ls -1 "$SP/replay" | wc -l | tr -d ' ')"
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in replay again crashme after cleana cleanb vanish notice report down up wsweepa wsweepb; do
  grep -qa "^tk " "$SP/$f.log" \
    || { echo "CRASH CHECK COULD NOT RUN -- tk never started in $f:"; sed -n '1,5p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done
[ "$copied" -ge 2 ] \
  || { echo "CRASH CHECK COULD NOT RUN -- only $copied of this app's own historical crash reports"
       echo "  are on this Mac, so the replay would prove nothing about older names."; exit 2; }
[ "$others" -ge 2 ] \
  || { echo "CRASH CHECK COULD NOT RUN -- only $others other applications' crash reports to"
       echo "  discriminate against, so a matcher that sends everything would pass."; exit 2; }

# ── 1. THE PARSER, ON REAL REPORTS FROM THREE OF THIS APP'S NAMES ───────────
echo "  -- replayed $copied of this app's own crash reports and $others other applications'"
[ "${REPLAY_ROWS:-0}" -eq $((copied + 1)) ] \
  && say "OK" "every one of this app's own reports came through, and only those ($REPLAY_ROWS of $((copied + others + 1)) files)" \
  || say "FAIL" "$REPLAY_ROWS reports were sent from $((copied + others + 1)) files -- expected $((copied + 1))"
# THE ARM THAT RANKS THE OTHER WAY. Without it, "it sent them" is equally
# consistent with a reporter that sends every .ips it can open.
OTHERAPPS="$(q 'sum(1 for r in rows if r.get("proc","") not in ("tk","tk_new","tkreal","Tokkah","Kin"))')"
[ "${OTHERAPPS:-1}" = "0" ] \
  && say "OK" "CONTROL: and not one crash belonging to another application" \
  || say "FAIL" "$OTHERAPPS other applications' crashes were reported as ours"
say "" "the names it recognised: $REPLAY_PROCS"
case "$REPLAY_PROCS" in
  *Tokkah*) say "OK" "including a crash from when this app was called Tokkah -- an older build's crash is not lost to the rename" ;;
  *) say "FAIL" "no Tokkah-era crash was recognised, and that is the population most worth hearing from" ;;
esac
[ "${REPLAY_SYNTH:-0}" = "1" ] \
  && say "OK" "and a report named Kin, which no build has produced yet" \
  || say "FAIL" "a report from the app's NEXT name was not recognised"
case "$REPLAY_WHERE" in
  *"()"*) say "OK" "each one names the line to open: $REPLAY_WHERE" ;;
  *) say "FAIL" "no crash carried a symbol from our own binary -- the stack explains nothing" ;;
esac
say "" "the versions that died: $REPLAY_VERSIONS (reported by $REPLAY_REPORTER)"
case "$REPLAY_VERSIONS" in
  *"0.27.0-test"*) say "OK" "the version that DIED is carried, not the version doing the reporting" ;;
  *) say "FAIL" "no crash carried the version it happened in, so 'did the release we just pushed break' is unanswerable" ;;
esac

# ── 2. WHAT IT REFUSES TO SEND ABOUT THE PERSON ─────────────────────────────
[ "${REPLAY_HOME:-1}" = "0" ] \
  && say "OK" "no crash carried this Mac's home directory path" \
  || say "FAIL" "$REPLAY_HOME crash(es) carried $HOME"
[ "${REPLAY_LEAK:-1}" = "0" ] \
  && say "OK" "and none carried the fields that identify a MACHINE (crash key, boot id, user id)" \
  || say "FAIL" "$REPLAY_LEAK crash(es) carried a machine identifier"
[ "${REPLAY_BIG:-0}" -le 6600 ] \
  && say "OK" "the biggest record was $REPLAY_BIG bytes, under the cap" \
  || say "FAIL" "a record reached $REPLAY_BIG bytes -- the cap did not hold"
[ -n "$REPLAY_CUT" ] \
  && say "OK" "a 120-frame stack arrived as $REPLAY_CUT frames -- cut by WHOLE FRAMES, and the total is still there" \
  || say "FAIL" "no long stack was trimmed, so nothing here proves how it is trimmed"
case "$REPLAY_DROPPED" in
  ?*) say "OK" "and the oversized record NAMES what it shed: $REPLAY_DROPPED" ;;
  *) say "FAIL" "the oversized record was cut silently, or not cut at all -- dropped=[$REPLAY_DROPPED]" ;;
esac
# The point of dropping whole fields rather than truncating the body: a record
# that had to shed weight still explains the crash. This project has shipped the
# other kind -- a truncated JSON body that parsed as a call blind to everything.
[ "$REPLAY_CORE" = "app_version,exc,sig,where" ] \
  && say "OK" "and it still says what died, how, and where ($REPLAY_CORE)" \
  || say "FAIL" "the record that shed weight lost the explanation too -- it kept only [$REPLAY_CORE]"

# ── 3. NEVER TWICE, AND NEVER THE WRONG ONE TWICE ───────────────────────────
[ "${AGAIN_ROWS:-0}" = "1" ] \
  && say "OK" "sweeping the same folder again sent exactly the ONE new report in it" \
  || say "FAIL" "the second sweep of the same folder sent $AGAIN_ROWS reports, not 1"
case "$AGAIN_IDS" in
  SYNTH-0000-0000-0000-000000000002) say "OK" "and it was the new one, so the mark is per crash and not an off switch" ;;
  *) say "FAIL" "the second sweep sent [$AGAIN_IDS] instead of the one new report" ;;
esac

# ── 4. A REAL CRASH, CAUSED ON PURPOSE, FOUND IN THE REAL FOLDER ────────────
say "" "macOS wrote $IPS_WRITTEN crash report(s) for the process this rig aborted"
[ "${REAL_HIT:-0}" -ge 1 ] \
  && say "OK" "a copy killed with SIGABRT was found in the machine's OWN crash folder and reported" \
  || say "FAIL" "a real crash of pid $CRASHED_PID was never reported"
say "" "and it was running as \"$REAL_PROC\" -- a name no build has ever used, recognised anyway"
case "$REAL_SIG" in
  *SIGABRT*) say "OK" "with the right signal ($REAL_SIG) and $REAL_OURS frame(s) in our own binary" ;;
  *) say "FAIL" "the real crash reported signal [$REAL_SIG]" ;;
esac
say "" "it had been running $REAL_RAN ms, which is the difference between a bad release and a bad call"
[ "${REAL_JOIN:-0}" -ge 1 ] \
  && say "OK" "and it is joined to the call it ended, so the beats leading up to it are findable" \
  || say "FAIL" "the crash was not joined to the call that was running when it happened"
[ "${REAL_VANISHED:-1}" = "0" ] \
  && say "OK" "CONTROL: and it was NOT also filed as an unexplained death -- one death, one record" \
  || say "FAIL" "the same death was reported twice, once with a stack and once without"

# ── 5. THE DEATH THAT LEAVES NO REPORT AT ALL ──────────────────────────────
[ "${NOTICE_ROWS:-1}" = "0" ] \
  && say "OK" "the launch that first NOTICED the SIGKILL reported nothing yet -- the report gets its chance to arrive" \
  || say "FAIL" "a death was called unexplained on the first sweep that saw it ($NOTICE_ROWS sent)"
[ "${VANISH_HIT:-0}" -ge 1 ] \
  && say "OK" "and the next launch reported it: a SIGKILL leaves no crash report and is caught anyway" \
  || say "FAIL" "a process killed with SIGKILL was never reported at all"
[ "${VANISH_CALL:-0}" -ge 1 ] \
  && say "OK" "with the call it was on, which is the only thing that can say when it died" \
  || say "FAIL" "the vanished run carried no call id, so there is nothing to date it by"
say "" "it says: $VANISH_WHY"
# The control's OWN PRECONDITION, asserted rather than assumed. If the pair never
# connected, or never filed an ending, then "no clean exit was reported as a
# death" is true for a reason that has nothing to do with this feature -- and
# that is exactly how a blind control passes. Checked first, and failing.
if grep -qa "connected via" "$SP/cleana.log" && grep -qa "final beat (terminated)" "$SP/cleana.log" \
   && grep -qa "final beat (terminated)" "$SP/cleanb.log"; then
  say "OK" "CONTROL: two copies really connected and both filed an ending when told to stop"
  [ "${CLEAN_DEATHS:-1}" = "0" ] \
    && say "OK" "CONTROL: and neither was reported as a death -- it discriminates" \
    || say "FAIL" "$CLEAN_DEATHS of the two clean exits were reported as unexplained deaths"
else
  say "FAIL" "the clean pair never connected or never filed an ending, so the control below is blind"
fi

# ── 6. A SEND THAT FAILED IS RETRIED, NOT LOST ─────────────────────────────
[ "${DOWN_ROWS:-1}" = "0" ] && [ "${DOWN_REFUSED:-0}" -ge 1 ] \
  && say "OK" "with the server refusing, the crash was attempted ($DOWN_REFUSED) and nothing was recorded as delivered" \
  || say "FAIL" "server down: $DOWN_ROWS delivered, $DOWN_REFUSED attempted"
[ "${UP_ROWS:-0}" -ge 1 ] \
  && say "OK" "and the next launch delivered the same crash -- a failed send is not a lost crash" \
  || say "FAIL" "the crash that could not be sent was never sent again"

# ── 7. THE ALWAYS-ON WATCHER, WHICH HAD NONE OF THIS ───────────────────────
[ "${WATCH_ROWS:-0}" -ge 1 ] \
  && say "OK" "the login item -- the process that lives all day and updates itself -- reports crashes too" \
  || say "FAIL" "the always-on watcher swept nothing; a crash on a Mac nobody opens Kin on stays invisible"
[ "${WATCH_KILL_DEATH:-0}" -ge 1 ] \
  && say "OK" "and a watcher killed outright IS reported as a death" \
  || say "FAIL" "a watcher killed with SIGKILL was never reported, so the control below is blind"
[ "${WATCH_TERM_DEATH:-1}" = "0" ] \
  && say "OK" "CONTROL: while one stopped the way launchd stops it at logout is NOT -- a logout is not a crash" \
  || say "FAIL" "a watcher stopped normally was filed as a death; every logout would look like one"

# ── 8. AND IT COSTS NOTHING WHEN NOTHING CRASHED ───────────────────────────
NOISE="$(python3 -c "print('%.1f' % abs(${COST_NULL:-0} - ${COST_EMPTY:-0}))")"
DELTA="$(python3 -c "print('%.1f' % (${COST_LOADED:-0} - ${COST_EMPTY:-0}))")"
say "" "launch to the microphone check, fastest of 9 rotated rounds:"
say "" "  empty folder ${COST_EMPTY} ms · a SECOND empty folder ${COST_NULL} ms · $COST_FILES reports ${COST_LOADED} ms"
say "" "  so this rig's own noise is ${NOISE} ms, and the crash folder is worth ${DELTA} ms"
# BLINDNESS FIRST. Every arm reading -1 would mean the marker line never appeared
# and all three "measurements" are the same non-answer, which would sail through
# any comparison between them.
python3 -c "import sys; sys.exit(0 if min(${COST_EMPTY:--1}, ${COST_NULL:--1}, ${COST_LOADED:--1}) > 5 else 1)" \
  || say "FAIL" "at least one arm never reached the marker -- these numbers are not measurements"
# One-sided on purpose: the claim is that a full crash folder does not make the
# launch SLOWER. A loaded arm that comes out faster is this Mac being busy, and
# turning that into a failure would be asserting on the rig's own noise.
python3 -c "import sys; sys.exit(0 if ${DELTA} <= max(${NOISE}, 3.0) + 5 else 1)" \
  && say "OK" "a full crash folder costs the launch ${DELTA} ms, inside this rig's own ${NOISE} ms of noise" \
  || say "FAIL" "a full crash folder cost the launch ${DELTA} ms against ${NOISE} ms of noise -- that is real"

echo
if [ "$fail" = 0 ]; then
  echo "CRASH CHECK PASSED -- a crash on a Mac we cannot see now reaches us, and a death with no crash report does too"
else
  echo "CRASH CHECK FAILED -- see above; logs in $SP"
  for f in replay again crashme after vanish notice report down up; do
    cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/crash-$f.log" 2>/dev/null
  done
  cp "$SINK.crash" "${SCRATCH:-${TMPDIR:-/tmp}}/crash-sink.crash" 2>/dev/null
fi
exit $fail
