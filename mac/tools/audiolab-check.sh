#!/bin/bash
# ── THE LISTENER'S NUMBERS, ON A REAL CALL ───────────────────────────────────
#
# `tk --selftest-audiolab` grades every ruler in AudioLab.swift on known inputs.
# It cannot see the one thing that matters most: whether the rulers are WIRED --
# whether the capture and render callbacks actually feed them on a live call, and
# whether the tapes actually land on disk with the lengths they claim. A ruler
# that is perfect and unplugged reads the same as no ruler
# (`dead-controls-declared-never-wired`).
#
# So: two real ends of a real loopback call, real speech from a file into each
# microphone, an echo path in software at end B, tapes on. Then read the beats
# the product itself wrote and the files it left, and refuse every field the
# contract (mac/TELEMETRY-AUDIO.md) promises that is missing, non-finite or wrong.
#
#   tools/audiolab-check.sh [seconds]
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "AUDIOLAB CHECK COULD NOT RUN -- no tk at $TK (swift build -c release)"; exit 2; }
SECS="${1:-24}"
SP="$(mktemp -d)"
R="al$$"
PIDS=""
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
nap() { perl -e "select undef,undef,undef,$1"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

MEDIA=""
for d in ../testbed/media/real testbed/media/real; do
  [ -f "$d/realA.wav" ] && [ -f "$d/realB.wav" ] && { MEDIA="$d"; break; }
done
[ -n "$MEDIA" ] || { echo "AUDIOLAB CHECK COULD NOT RUN -- no realA.wav/realB.wav under testbed/media/real"; exit 2; }

# `--mute` keeps the room this rig runs in quiet; the echo path under test is the
# simulated one. `--no-floor` because a floor that mutes end B's microphone while
# A talks leaves no echo to return -- the floor has its own rig. `--no-aec` at B so
# the return is not cancelled before it can be measured. `--route speakers` pins
# the route (a pair of earbuds would stand the whole echo machinery down).
COMMON=(--video off --mute --no-update --no-relocate --no-rings --no-subtitles
        --no-floor --no-aec --route speakers --tel-endpoint "http://127.0.0.1:9/beat")

# Lab mode for both rig installs, in scratch identity dirs the real Kin never sees.
for e in a b c d; do
  mkdir -p "$SP/$e"
  TK_KIN_DIR="$SP/$e" "$TK" --lab on >/dev/null 2>&1
done
rm -f "$SP/d/lab.json"          # end d has no lab.json at all: the second reject

echo "AUDIO LAB CHECK  two real ends, ${SECS}s, echo path 22 ms / 0.55 at end B, tapes on"
echo
TK_KIN_DIR="$SP/a" TK_TAPES_DIR="$SP/tapes-a" "$TK" "${COMMON[@]}" --room "$R" --listen 7431 --peer 127.0.0.1:7432 \
  --audio "$MEDIA/realA.wav" > "$SP/a.log" 2>&1 & PIDS="$PIDS $!"
TK_KIN_DIR="$SP/b" TK_TAPES_DIR="$SP/tapes-b" "$TK" "${COMMON[@]}" --room "$R" --listen 7432 --peer 127.0.0.1:7431 \
  --audio "$MEDIA/realB.wav" --echo-sim 22:0.55 > "$SP/b.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 1 60); do
  V="$(grep -oE 'recv [0-9]+/s' "$SP/a.log" | tail -1 | grep -oE '[0-9]+')"
  [ "${V:-0}" -gt 500 ] && break; nap 0.5
done
[ "${V:-0}" -gt 500 ] \
  && say OK "media flowing at ${V}/s" \
  || { echo "  AUDIOLAB CHECK COULD NOT RUN -- never got a call (recv ${V:-0}/s)"; sed -n '1,30p' "$SP/a.log"; exit 2; }
nap "$SECS"
# A clean ending, so the tapes are finished and the final beat carries their size.
for p in $PIDS; do kill -INT "$p" 2>/dev/null; done
nap 3
reap

echo "── A. every promised field, present and finite, on both ends"
check_beats() {                 # $1 = end letter, $2 = beats.ndjson
  python3 - "$1" "$2" <<'PY'
import json, sys, math
end, path = sys.argv[1], sys.argv[2]
bs = []
for ln in open(path, errors="replace"):
    ln = ln.strip()
    if not ln: continue
    try: bs.append(json.loads(ln))
    except Exception: pass
live = [b for b in bs if b.get("phase") in ("live", "final")]
fail = 0
def say(ok, what):
    global fail
    print(f"  {'OK   ' if ok else 'FAIL '} end {end}: {what}")
    if not ok: fail += 1
say(len(live) >= 3, f"{len(live)} live beats")
cumul = ["a_rx_voice_ms","a_rx_conceal_voiced_ms","a_rx_conceal_quiet_ms","a_rx_glitches","a_rx_silence_ms",
         "a_rx_clip_pct","a_rate_fast_ms","a_rate_max_pct","a_tx_voice_ms","a_tx_voice_muted_ms",
         "a_tx_softlimit_pct","a_echo_talk_s","a_echo_return_s","tape_bytes","tape_full","in_rate","out_rate"]
# `a_rx_noise_db` is deliberately not required: it needs far-end PAUSES, and a
# recording that talks for the whole call has none to measure -- absent is the
# right answer there, not a fault.
window = ["a_rx_level_db_p50","a_rx_level_db_p90","a_tx_level_db_p50","a_tx_noise_db",
          "a_tx_snr_db","a_rx_bw_khz","a_tx_bw_khz"]
last = live[-1]
missing = [k for k in cumul if not isinstance(last.get(k), (int, float))]
say(not missing, "every cumulative field present" if not missing else f"missing cumulative fields: {missing}")
bad = [k for b in live for k, v in b.items() if k.startswith("a_") and isinstance(v, float) and not math.isfinite(v)]
say(not bad, "every a_* value finite" if not bad else f"non-finite: {sorted(set(bad))}")
seen = {k for b in live for k in b if k in window}
say(seen == set(window), "every window field appeared at least once" if seen == set(window) else f"window fields never seen: {sorted(set(window)-seen)}")
def L(k, d=0):
    v = last.get(k); return v if isinstance(v, (int, float)) else d
say(L("a_rx_voice_ms") > 3000, f"far voice heard for {L('a_rx_voice_ms')/1000:.1f} s")
say(L("a_tx_voice_ms") > 3000, f"near voice for {L('a_tx_voice_ms')/1000:.1f} s")
def med(k):
    s = sorted(v for b in live for v in [b.get(k)] if isinstance(v, (int, float)))
    return s[len(s)//2] if s else None
rb, tb = med("a_rx_bw_khz"), med("a_tx_bw_khz")
# The ruler moves one 1/6-octave band with the 24 s of content a run lands on
# (realA has read 6.4, 7.2 and 9.0 across runs; realB 5.7, 6.4 and 8.1), so the
# absolute bar is the one the product uses: real speech is NOT a telephone band,
# >= 4.5 kHz, which is where `telemetry.py` says "telephone-grade". The strong
# assertion is the cross-check after both ends: the same voice must read the same
# at the end that sent it and the end that heard it, because the wire is lossless.
mine = "realA" if end == "a" else "realB"
say(tb is not None and tb >= 4.5, f"sent bandwidth {tb} kHz ({mine}, not a telephone band: >= 4.5)")
say(rb is not None and rb >= 4.5, f"heard bandwidth {rb} kHz ({'realB' if end == 'a' else 'realA'}, not a telephone band: >= 4.5)")
say(L("in_rate") == 48000 and L("out_rate") == 48000, f"in_rate {L('in_rate')} out_rate {L('out_rate')} (48000, were 0 before)")
facts = {}
for b in live:
    if isinstance(b.get("facts"), dict): facts.update(b["facts"])
need = ["in_dev","in_transport","in_rate_hw","in_ch","out_dev","out_transport","out_rate_hw","out_ch","bt_hfp","lab","tapes"]
mf = [k for k in need if k not in facts]
say(not mf, f"device and lab facts present (bt_hfp={facts.get('bt_hfp')}, in={facts.get('in_transport')}, tapes={facts.get('tapes')})" if not mf else f"facts missing: {mf}")
say(facts.get("lab") == "on", f"lab fact reads on ({facts.get('lab')})")
say(L("tape_bytes") > 1_000_000, f"tape_bytes {L('tape_bytes')} (> 1 MB)")
say(L("tape_full") == 0, f"tape_full {L('tape_full')} (no ring overran the drain)")
print(f"RESULT {fail} {L('a_echo_talk_s')} {L('a_echo_return_s')} {L('conceal_total')} {L('a_tx_voice_muted_ms')} {tb} {rb}")
PY
}
RA="$(check_beats a "$SP/a/logs/beats.ndjson")"; echo "$RA" | grep -v '^RESULT'
RB="$(check_beats b "$SP/b/logs/beats.ndjson")"; echo "$RB" | grep -v '^RESULT'
FA=$(echo "$RA" | awk '/^RESULT/{print $2}'); FB=$(echo "$RB" | awk '/^RESULT/{print $2}')
[ "${FA:-1}" = 0 ] && [ "${FB:-1}" = 0 ] || fail=1
# The transport is lossless, so the voice that left one end must read the same
# bandwidth at the end that heard it -- within one 1/6-octave band (12%).
TXA=$(echo "$RA" | awk '/^RESULT/{print $7}'); RXB=$(echo "$RB" | awk '/^RESULT/{print $8}')
TXB=$(echo "$RB" | awk '/^RESULT/{print $7}'); RXA=$(echo "$RA" | awk '/^RESULT/{print $8}')
python3 - "$TXA" "$RXB" "$TXB" "$RXA" <<'PY' || fail=1
import sys
def f(v):
    try: return float(v)
    except Exception: return None
txa, rxb, txb, rxa = map(f, sys.argv[1:5])
ok = 0
for what, s, h in (("realA: sent by A vs heard at B", txa, rxb), ("realB: sent by B vs heard at A", txb, rxa)):
    good = s is not None and h is not None and 0.84 <= h / s <= 1.19
    print(f"  {'OK   ' if good else 'FAIL '} {what}: {s} vs {h} kHz (within one band)")
    ok += 0 if good else 1
sys.exit(1 if ok else 0)
PY

echo "── B. my voice, returning: end A hears itself (B has the echo path), end B does not"
TA=$(echo "$RA" | awk '/^RESULT/{print $3}'); RTA=$(echo "$RA" | awk '/^RESULT/{print $4}')
TB=$(echo "$RB" | awk '/^RESULT/{print $3}'); RTB=$(echo "$RB" | awk '/^RESULT/{print $4}')
[ "${TA:-0}" -ge 5 ] && say OK "end A talked for ${TA} s of measured windows" || { say FAIL "end A talked ${TA:-0} s -- nothing to measure"; fail=1; }
[ "${RTA:-0}" -ge 2 ] && say OK "end A heard itself back in ${RTA} s (echo-sim at B)" || { say FAIL "end A heard itself in ${RTA:-0} s -- the return was not seen"; fail=1; }
[ "${RTB:-0}" -le $(( ${TB:-0} / 5 )) ] && say OK "end B heard itself in ${RTB} of ${TB} s (no echo path at A) -- REJECT row" \
  || { say FAIL "end B reads ${RTB} of ${TB} s of return with no echo path -- a false positive"; fail=1; }

echo "── C. the tapes: on disk, the right length, and their timeline agrees with the beat"
check_tape() {                  # $1 = end, $2 = tapes dir, $3 = beats.ndjson
  python3 - "$1" "$2" "$3" "$SECS" <<'PY'
import json, sys, os, struct, glob
end, base, beats, secs = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
fail = 0
def say(ok, what):
    global fail
    print(f"  {'OK   ' if ok else 'FAIL '} end {end}: {what}")
    if not ok: fail += 1
dirs = glob.glob(os.path.join(base, "*"))
say(len(dirs) == 1, f"one tape directory ({len(dirs)})")
if not dirs: print(f"RESULT {fail}"); raise SystemExit
d = dirs[0]
def wav_samples(name, bps):
    p = os.path.join(d, name)
    if not os.path.exists(p): return -1
    with open(p, "rb") as f:
        h = f.read(46)
        size = os.path.getsize(p)
    declared = struct.unpack("<I", h[42:46])[0]
    if declared != size - 46: return -2
    return declared // bps
raw, sent, played = wav_samples("raw.wav", 4), wav_samples("sent.wav", 2), wav_samples("played.wav", 2)
dur = lambda n: n / 48000.0
lo = secs - 3
say(raw > 0 and abs(dur(raw) - dur(sent)) < 2.5 and dur(sent) > lo, f"raw {dur(raw):.1f} s, sent {dur(sent):.1f} s (call ~{secs:.0f} s, headers agree with file sizes)")
say(played > 0 and dur(played) > lo, f"played {dur(played):.1f} s")
rb = os.path.getsize(os.path.join(d, "render.bin")) // 32
cb = os.path.getsize(os.path.join(d, "capture.bin")) // 32
say(abs(rb - dur(played) * 3000) < dur(played) * 3000 * 0.05 + 100, f"render.bin {rb} records (~{dur(played)*3000:.0f} for 16-sample callbacks)")
say(abs(cb - dur(sent) * 1500) < dur(sent) * 1500 * 0.05 + 100, f"capture.bin {cb} records (~{dur(sent)*1500:.0f} packets)")
# Concealed samples in the timeline against the beat's own count.
conc = 0
with open(os.path.join(d, "render.bin"), "rb") as f:
    while True:
        rec = f.read(32)
        if len(rec) < 32: break
        conc += struct.unpack("<H", rec[18:20])[0]
bs = [json.loads(l) for l in open(beats, errors="replace") if l.strip()]
live = [b for b in bs if b.get("phase") in ("live", "final")]
bc = (live[-1].get("conceal_total", 0) or 0) * 32 if live else -1
say(abs(conc - bc) <= max(64, bc * 0.02), f"timeline concealed {conc} samples vs beat {bc} (within 2%)")
m = json.load(open(os.path.join(d, "meta.json")))
say("duration_s" in m and "samples" in m and m["samples"].get("sent") == sent, f"meta.json final: duration {m.get('duration_s', 0):.1f} s, samples agree")
say(not any(m.get("full", {}).values()), f"no stream ran full: {m.get('full')}")
print(f"RESULT {fail}")
PY
}
CA="$(check_tape a "$SP/tapes-a" "$SP/a/logs/beats.ndjson")"; echo "$CA" | grep -v '^RESULT'
CB="$(check_tape b "$SP/tapes-b" "$SP/b/logs/beats.ndjson")"; echo "$CB" | grep -v '^RESULT'
[ "$(echo "$CA" | awk '/^RESULT/{print $2}')" = 0 ] && [ "$(echo "$CB" | awk '/^RESULT/{print $2}')" = 0 ] || fail=1

echo "── D. the two ways a tape must NOT appear: --no-tapes, and no lab.json"
TK_KIN_DIR="$SP/c" TK_TAPES_DIR="$SP/tapes-c" "$TK" "${COMMON[@]}" --no-tapes --room "${R}c" --listen 7433 --peer 127.0.0.1:7434 \
  --audio "$MEDIA/realA.wav" > "$SP/c.log" 2>&1 & PIDS="$PIDS $!"
TK_KIN_DIR="$SP/d" TK_TAPES_DIR="$SP/tapes-d" "$TK" "${COMMON[@]}" --room "${R}c" --listen 7434 --peer 127.0.0.1:7433 \
  --audio "$MEDIA/realB.wav" > "$SP/d.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 1 60); do
  V="$(grep -oE 'recv [0-9]+/s' "$SP/c.log" | tail -1 | grep -oE '[0-9]+')"
  [ "${V:-0}" -gt 500 ] && break; nap 0.5
done
nap 4
for p in $PIDS; do kill -INT "$p" 2>/dev/null; done
nap 2
reap
[ -d "$SP/tapes-c" ] && say FAIL "--no-tapes wrote a tape directory" && fail=1 || say OK "--no-tapes: no tape directory -- REJECT row"
[ -d "$SP/tapes-d" ] && say FAIL "an install with no lab.json wrote a tape directory" && fail=1 || say OK "no lab.json: no tape directory -- REJECT row"
grep -q '"lab":"off"' "$SP/d/logs/beats.ndjson" 2>/dev/null && say OK "and its beat says lab off" || { say FAIL "end d's beat does not say lab off"; fail=1; }

echo "── E. the cost: the render callback's own worst-case, with tapes on"
# The stat line prints `work p50 N us p99 N us` for the render callback.
COST="$(grep -oE 'work p50 [0-9]+ us p99 [0-9]+ us' "$SP/a.log" | tail -1 | sed -E 's/.*p99 ([0-9]+) us/\1/')"
if [ -n "$COST" ]; then
  [ "$COST" -lt 100 ] \
    && say OK "render work p99 ${COST} us with tapes on (< 100)" \
    || { say FAIL "render work p99 ${COST} us with tapes on"; fail=1; }
else
  say FAIL "no 'work p50 .. p99 ..' line in the log to judge the cost by"; fail=1
fi

echo
if [ "$fail" = 0 ]; then echo "AUDIOLAB CHECK: ALL PASSED"; else echo "AUDIOLAB CHECK: FAILED"; fi
exit $fail
