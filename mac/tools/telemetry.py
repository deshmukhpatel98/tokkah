"""Reads what tools/telemetry.sh fetches. Prints the numbers a call is judged on
rather than the whole beat: a 80 KB JSON dump is data nobody looks at twice."""
import json, sys, datetime

def num(b, k, d=None):
    v = b.get(k)
    return v if isinstance(v, (int, float)) else d

def series(bs, k):
    return [v for v in (num(b, k) for b in bs) if v is not None]

def last(bs, k, d=0):
    s = series(bs, k)
    return s[-1] if s else d

def call_summary(bs, label=""):
    """Three lines, grouped by the question each one answers, because a single
    run-on line of eleven numbers is a line nobody reads twice."""
    if not bs:
        print("  no beats"); return
    ec = series(bs, "echo_corr")
    peak = series(bs, "echo_corr_peak")
    # The PEAK, not the last value. echo_corr is an instant: the final beat of a
    # call that reached 0.71 read 0.04, so a summary built on the last value said
    # "no echo" about a call with a measured one.
    top = max(peak) if peak else (max(ec) if ec else 0)
    over = sum(1 for x in ec if x > 0.45)
    print(f"  ECHO      peak {top:.2f}  ·  over 0.45 in {over}/{len(ec)} beats"
          f"  ·  speaker fed the mic on {'YES' if top > 0.45 else 'no'}")
    # Whether the fix under test fired at all. "It fired and did not help" and
    # "it never fired" are different bugs and used to look identical.
    gp, ip = last(bs, "echo_guard_pct", -1), last(bs, "echo_guard_idle_pct", -1)
    guard = (f"idle-guard muted {gp:.0f}% of the call (idle was {ip:.0f}%)"
             if gp >= 0 else "idle-guard: not in this build")
    print(f"  MIC       floor muted {last(bs,'floor_muted_pct'):.0f}%"
          f"  ·  {guard}"
          f"  ·  local gate open {last(bs,'floor_held_pct'):.0f}%")
    trim, rail = last(bs, "mic_trim", 1), last(bs, "mic_gain_rail", 0)
    pr, ps = last(bs, "predict_releases", -1), last(bs, "predict_saved_ms", 0)
    early = f"handed over early {pr:.0f}x saving {ps:.0f} ms" if pr >= 0 else "predictor: not in this build"
    print(f"  TURNS     both talking {last(bs,'turn_collisions'):.0f}"
          f"  ·  choppy {last(bs,'turn_flaps'):.0f}"
          f"  ·  gave way {last(bs,'turn_yields'):.0f}"
          f"  ·  to-audible p50 {last(bs,'turn_to_floor_p50'):.0f} ms"
          f"  ·  {early}")
    print(f"  MIC LEVEL trim {trim:.2f}{' (AT THE RAIL)' if rail else ''}"
          f"  ·  peak {last(bs,'a_mic_peak'):.2f}  ·  rms {last(bs,'a_mic_rms'):.3f}"
          f"  ·  clipping {last(bs,'a_clip_pct'):.2f}%"
          f"  ·  fallback {last(bs,'floor_fallback_pct'):.1f}%")

mode = sys.argv[1]
if mode == "local":
    bs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
    calls = {}
    for b in bs: calls.setdefault(b.get("call", "?"), []).append(b)
    for c, rows in list(calls.items())[-10:]:
        print(f"{c}  {rows[-1].get('version','')}  {len(rows)} beats")
        call_summary(rows)
    sys.exit()

d = json.load(sys.stdin)
if mode == "call":
    call_summary(d.get("beats", []))
elif mode == "pairids":
    want = sys.argv[2]
    cs = d.get("calls", [])
    me = next((c for c in cs if c.get("call") == want), None)
    print(want)
    if me:
        # The other end is the call that overlaps this one in time from a
        # DIFFERENT install: one end's record can never say who stopped first.
        for c in cs:
            if c.get("call") == want or c.get("install") == me.get("install"): continue
            if abs(c.get("startedAt", 0) - me.get("startedAt", 0)) < 20 and c.get("durationS", 0) > 5:
                print(c["call"])
elif mode == "recent":
    cs = [c for c in d.get("calls", []) if c.get("durationS", 0) > 0]
    print(f"{'call':>14} {'install':>13} {'ver':>7} {'when':>9} {'secs':>5} "
          f"{'mic%':>5} {'echo':>5} {'both':>5} {'choppy':>7} {'gaveway':>8}")
    for c in cs:
        t = datetime.datetime.fromtimestamp(c.get("startedAt", 0)).strftime("%H:%M:%S")
        print(f"{c.get('call',''):>14} {c.get('install','')[:11]:>13} {c.get('version',''):>7} {t:>9} "
              f"{c.get('durationS',0):>5} {c.get('floor_held_pct',-1):>5.0f} {c.get('echo_corr',-1):>5.2f} "
              f"{c.get('turn_collisions',-1):>5} {c.get('turn_flaps',-1):>7} {c.get('turn_yields',-1):>8}")
