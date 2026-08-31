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

def sub(bs, group, k, d=None):
    """Newest value of beats[i][group][k] -- counters and facts ride nested."""
    for b in reversed(bs):
        g = b.get(group)
        if isinstance(g, dict) and k in g:
            return g[k]
    return d

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
    # strict (0.95.0): one mic, one speaker, never the same end. `overlap` is
    # its honesty meter -- on the wire while the far stream also carried voice.
    st = last(bs, "floor_strict", -1)
    mode = ("STRICT floor" if st == 1 else "soft floor" if st == 0 else "pre-strict build")
    ov = last(bs, "strict_overlap_pct", -1)
    if st == 1 and ov >= 0:
        mode += f", overlap {ov:.1f}%"
    print(f"  MIC       {mode}"
          f"  ·  floor muted {last(bs,'floor_muted_pct'):.0f}%"
          f"  ·  {guard}"
          f"  ·  local gate open {last(bs,'floor_held_pct'):.0f}%")
    trim, rail = last(bs, "mic_trim", 1), last(bs, "mic_gain_rail", 0)
    pr, ps = last(bs, "predict_releases", -1), last(bs, "predict_saved_ms", 0)
    fr, fs = last(bs, "predict_far_releases", -1), last(bs, "predict_far_saved_ms", 0)
    # The PEAK of what they sent, not the last value -- a call whose prior
    # reached 0.8 and ended at 0.0 would otherwise look like the byte never moved.
    ppeak = series(bs, "predict_peer_p_peak")
    pnow = series(bs, "predict_peer_p_now")
    theirp = max(ppeak) if ppeak else (max(pnow) if pnow else -1)
    if pr >= 0:
        early = f"handed over early {pr:.0f}x saving {ps:.0f} ms"
        if fr >= 0:
            early += f" (far {fr:.0f}x / {fs:.0f} ms"
            early += f", their p peaked {theirp:.2f})" if theirp >= 0 else ", their p: not in this build)"
    else:
        early = "predictor: not in this build"
    # onset-to-wire (0.98.0): first block of voice -> on the wire. THE number
    # for "latency deciding who is speaking"; -1 means an older build.
    ow = last(bs, "turn_onset_to_wire_p50", -1)
    lost = last(bs, "turn_onset_lost", -1)
    onset = (f"onset->wire p50 {ow:.0f} ms" if ow >= 0 else "onset->wire: not in this build")
    if lost > 0:
        onset += f" ({lost:.0f} never got out)"
    print(f"  TURNS     both talking {last(bs,'turn_collisions'):.0f}"
          f"  ·  choppy {last(bs,'turn_flaps'):.0f}"
          f"  ·  gave way {last(bs,'turn_yields'):.0f}"
          f"  ·  {onset}"
          f"  ·  {early}")
    # The interjection rescue (0.99.0). `grace_onsets` counts utterances that
    # 0.98.0 would have deleted outright; `fast_takes` the floors won by the
    # 180 ms voice contest instead of the 1150 ms claim contest.
    # `gcp`, not `gp`: `gp` above is the echo-guard percentage and is still
    # live in this scope.
    gcp = last(bs, "turn_grace_pct", -1)
    if gcp >= 0:
        print(f"  INTERJECT rescued {last(bs,'turn_grace_onsets'):.0f}"
              f"  ·  audible-over-holder {gcp:.1f}% of the call"
              f"  ·  fast floor takes {last(bs,'turn_fast_takes'):.0f}")
    # The camera's turn-taking signal (0.100.0). `looks`/`faces` separate "never
    # ran" from "ran and saw nobody" from "saw somebody sitting quietly".
    lk = last(bs, "mouth_looks", -1)
    if lk > 0:
        fc = last(bs, "mouth_faces", 0)
        mv = last(bs, "mouth_moving_pct", -1)
        seen = f"face in {fc * 100 / lk:.0f}% of {lk:.0f} looks"
        mvs = f"mouth moving {mv:.0f}%" if mv >= 0 else "no verdict yet"
        print(f"  CAMERA    {seen}  ·  {mvs}"
              f"  ·  rescued from echo-veto {last(bs,'mouth_unveto_pct'):.1f}% of samples"
              f"  ·  visual floor takes {last(bs,'turn_visual_takes'):.0f}"
              f"  ·  dropped {last(bs,'mouth_dropped'):.0f}")
    elif lk == 0:
        print("  CAMERA    the detector never ran (no camera frames)")
    # corr-veto: how much of the call the classifier refused to call the
    # machine's own speaker a voice (0.94.0). -1 means an older build.
    cv = last(bs, "a_corr_veto_pct", -1)
    veto = f"corr-veto {cv:.1f}%" if cv >= 0 else "corr-veto: not in this build"
    print(f"  MIC LEVEL trim {trim:.2f}{' (AT THE RAIL)' if rail else ''}"
          f"  ·  peak {last(bs,'a_mic_peak'):.2f}  ·  rms {last(bs,'a_mic_rms'):.3f}"
          f"  ·  clipping {last(bs,'a_clip_pct'):.2f}%"
          f"  ·  fallback {last(bs,'floor_fallback_pct'):.1f}%"
          f"  ·  {veto}")
    # The ring story (0.96.0): who rang, what stopped it, and how late the
    # cancel landed. "It kept ringing" was undiagnosable from a beat before.
    rr = (sub(bs, "events", "ring_recv", 0) or 0) + (sub(bs, "events", "ring_recv_watch", 0) or 0)
    if rr:
        stops = []
        for k, word in (("bye_recv_ringing", "stopped by bye"),
                        ("bye_note_ringing", "stopped by note"),
                        ("bye_note_prering", "cancelled before it rang"),
                        ("ring_declined", "declined"),
                        ("ring_reexec", "handed to a face-card image")):
            n = sub(bs, "events", k, 0) or 0
            if n:
                stops.append(f"{word} {n}x")
        rms, bms = sub(bs, "marks", "ring_recv_ms"), sub(bs, "marks", "bye_recv_ms")
        lag = (f"  ·  cancel landed {bms - rms:.0f} ms after the ring"
               if isinstance(rms, (int, float)) and isinstance(bms, (int, float)) and bms >= rms else "")
        slow = (sub(bs, "events", "ring_poll_slow", 0) or 0) > 0
        out = sub(bs, "facts", "outcome")
        print(f"  RING      rang {rr}x  ·  " + (" · ".join(stops) if stops else "no stop recorded")
              + lag + ("  ·  POLL WENT SLOW (server stopped holding)" if slow else "")
              + (f"  ·  {out}" if out else ""))
    # Where this end was, once per connected call (0.96.0) -- ~1 km grain.
    la, lo = sub(bs, "facts", "geo_lat"), sub(bs, "facts", "geo_lon")
    ge = sub(bs, "facts", "geo_err")
    if la and lo:
        print(f"  WHERE     {la}, {lo}  (±{sub(bs, 'facts', 'geo_acc_km', '?')} km)")
    elif ge:
        print(f"  WHERE     no location ({ge})")

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
