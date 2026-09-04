"""Reads what tools/telemetry.sh fetches. Prints the numbers a call is judged on
rather than the whole beat: a 80 KB JSON dump is data nobody looks at twice."""
import math
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

def last_str(bs, k, d=""):
    """Newest non-empty string value of beats[i][k]."""
    for b in reversed(bs):
        v = b.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
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
    # The canceller (0.107.0+), as a ranked story: how much it removed, how much
    # path is LEFT (the number the duplex gate reads), and whether the aim held.
    # 0.125.0 added the last three: re-aims the hold refused, drift fits rejected
    # as a wandering estimator, and how much of the call both mics were open on
    # loudspeakers because the canceller had earned it.
    erle = series(bs, "aec_erle_db")
    if erle:
        import statistics
        res = series(bs, "aec_residual")
        path_db = 20 * math.log10(max(1e-4, statistics.median(res))) if res else 0
        held = last(bs, "aec_reaims_held", -1)
        rej = last(bs, "aec_skew_rejects", -1)
        dup = last(bs, "floor_aec_duplex_pct", -1)
        nl = last(bs, "aec_nl_share_db", None)
        print(f"  CANCELLER removed p50 {statistics.median(erle):.1f} dB peak {max(erle):.1f}"
              f"  ·  call {last(bs,'aec_erle_life_db'):.1f} dB"
              f"  ·  path left {path_db:.0f} dB"
              f"  ·  subtracting {100-last(bs,'aec_off_pct',100):.0f}% of the call"
              f"  ·  re-aims {last(bs,'aec_reaims',0):.0f}"
              + (f" (held {held:.0f})" if held >= 0 else " (hold: not in this build)")
              + f"  ·  drift {last(bs,'aec_skew_sps',0):.2f} sps"
              + (f" ({rej:.0f} fits rejected)" if rej >= 0 else "")
              + f"  ·  resets {last(bs,'aec_diverges',0):.0f}"
              + (f"  ·  both mics open on speakers {dup:.0f}%" if dup >= 0 else "")
              + (f"  ·  distortion share {nl:.0f} dB" if nl is not None and last(bs,'aec_nl_on',0) else ""))
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
        # Their camera, over the wire (0.102.0). -1 = they cannot say.
        pk = last(bs, "peer_seen_talking", -2)
        theirs = ("their camera: not in their build / no face" if pk < 0
                  else "their camera reported" if pk >= 0 else "")
        print(f"  THEIR CAM {theirs}"
              f"  ·  released my finished turn on sight {last(bs,'turn_seen_releases'):.0f}x")
    mk = last(bs, "mic_makeup", 1)
    if mk > 1.02:
        print(f"  DISTANT   makeup gain +{20 * __import__('math').log10(mk):.0f} dB"
              f"  ({mk:.1f}x) -- a far-away talker was lifted to a normal level")
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
    # Which launch path produced this call (0.107.0). The first question to ask
    # of a bad call: a compound failure is two changes at once, and this says
    # which half was in play without asking anybody to retype a command.
    # `direct` is a real third answer (a link, a ring, a resumed call), not a
    # stand-in for "could not tell" -- absent means a build older than the fact.
    lp = sub(bs, "facts", "launch_path")
    if lp:
        print(f"  LAUNCH    {lp}")
    # Where this end was, once per connected call (0.96.0) -- ~1 km grain.
    la, lo = sub(bs, "facts", "geo_lat"), sub(bs, "facts", "geo_lon")
    ge = sub(bs, "facts", "geo_err")
    if la and lo:
        print(f"  WHERE     {la}, {lo}  (±{sub(bs, 'facts', 'geo_acc_km', '?')} km)")
    elif ge:
        print(f"  WHERE     no location ({ge})")

    # ── VPN / ROUTE ─────────────────────────────────────────────────────────
    von = last(bs, "vpn_on", 0)
    vrouted = last(bs, "vpn_routed", 0)
    vrc = last_str(bs, "vpn_relay_country")
    vrcity = last_str(bs, "vpn_relay_city")
    vrcolo = last_str(bs, "vpn_relay_colo")
    vrrtt = last(bs, "vpn_relay_rtt_ms", None)
    vpsent = last(bs, "vpn_packets_sent", 0)
    vprecv = last(bs, "vpn_packets_recv", 0)
    myc = last_str(bs, "vpn_my_country")
    peerc = last_str(bs, "vpn_peer_country")

    if not vrc: vrc = sub(bs, "facts", "vpn_relay_country") or ""
    if not myc: myc = sub(bs, "facts", "vpn_my_country") or ""
    if not peerc: peerc = sub(bs, "facts", "vpn_peer_country") or ""

    if von or vrouted or vrc or (vrrtt is not None and vrrtt >= 0) or (myc and peerc):
        loc_str = f"{vrc}" if vrc else "unknown"
        if vrcity: loc_str += f" ({vrcity}" + (f", {vrcolo}" if vrcolo else "") + ")"
        elif vrcolo: loc_str += f" ({vrcolo})"

        status = "ROUTED via VPN relay" if vrouted else ("VPN ON (idle/waiting)" if von else "VPN off")
        rtt_info = f"relay RTT {vrrtt:.1f} ms" if (vrrtt is not None and vrrtt >= 0) else ""
        pkts = f"pkts sent {vpsent} / recv {vprecv}" if (vpsent > 0 or vprecv > 0) else ""
        route_parts = [status, f"relay: {loc_str}"]
        if rtt_info: route_parts.append(rtt_info)
        if pkts: route_parts.append(pkts)
        if myc or peerc:
            route_parts.append(f"endpoints: {myc or '?'} <-> {peerc or '?'}")
        print(f"  VPN       " + "  ·  ".join(route_parts))

    # ── LATENCY ─────────────────────────────────────────────────────────────
    rtt_s = series(bs, "rtt_ms")
    rtt_jit_s = series(bs, "rtt_jit_ms")
    g2g_50_s = series(bs, "g2g_p50")
    g2g_95_s = series(bs, "g2g_p95")
    g2g_99_s = series(bs, "g2g_p99")
    m2e_50_s = series(bs, "m2e_p50")
    m2e_95_s = series(bs, "m2e_p95")
    m2e_99_s = series(bs, "m2e_p99")
    slack_50_s = series(bs, "slack_p50")
    slack_01_s = series(bs, "slack_p01")

    if rtt_s or g2g_50_s or m2e_50_s:
        import statistics
        rtt_med = statistics.median(rtt_s) if rtt_s else 0
        rtt_jit = statistics.median(rtt_jit_s) if rtt_jit_s else 0
        g2g_50 = statistics.median(g2g_50_s) if g2g_50_s else 0
        g2g_95 = statistics.median(g2g_95_s) if g2g_95_s else (max(g2g_95_s) if g2g_95_s else 0)
        g2g_99 = statistics.median(g2g_99_s) if g2g_99_s else (max(g2g_99_s) if g2g_99_s else 0)
        m2e_50 = statistics.median(m2e_50_s) if m2e_50_s else 0
        m2e_95 = statistics.median(m2e_95_s) if m2e_95_s else 0
        m2e_99 = statistics.median(m2e_99_s) if m2e_99_s else 0
        sl_50 = statistics.median(slack_50_s) if slack_50_s else 0
        sl_01 = min(slack_01_s) if slack_01_s else 0

        g2g_parts = [f"g2g p50 {g2g_50:.1f} ms"]
        if g2g_95 > 0: g2g_parts.append(f"p95 {g2g_95:.1f}")
        if g2g_99 > 0: g2g_parts.append(f"p99 {g2g_99:.1f}")
        g2g_str = " ".join(g2g_parts)

        m2e_parts = [f"m2e p50 {m2e_50:.1f} ms"]
        if m2e_95 > 0: m2e_parts.append(f"p95 {m2e_95:.1f}")
        if m2e_99 > 0: m2e_parts.append(f"p99 {m2e_99:.1f}")
        m2e_str = " ".join(m2e_parts)
        print(f"  LATENCY   rtt p50 {rtt_med:.1f} ms (jit {rtt_jit:.1f} ms)"
              f"  ·  {g2g_str}"
              f"  ·  {m2e_str}"
              f"  ·  slack p50 {sl_50:.1f} ms (p01 {sl_01:.1f} ms)")

    # ── VISUALS ─────────────────────────────────────────────────────────────
    vshown = last(bs, "v_shown", 0)
    vdec = last(bs, "v_decoded", 0)
    vsent = last(bs, "v_sent", 0)
    mbps_s = series(bs, "v_mbps")
    bpf_s = series(bs, "v_bytes_frame")
    enc_fps_s = series(bs, "v_enc_ps")
    dec_fps_s = series(bs, "v_dec_ps")

    if vshown > 0 or vdec > 0 or vsent > 0 or mbps_s:
        import statistics
        enc_fps = statistics.median(enc_fps_s) if enc_fps_s else 0
        dec_fps = statistics.median(dec_fps_s) if dec_fps_s else 0
        mbps_med = statistics.median(mbps_s) if mbps_s else 0
        mbps_max = max(mbps_s) if mbps_s else 0
        bpf_med = statistics.median(bpf_s) if bpf_s else 0
        bpf_max = max(bpf_s) if bpf_s else 0
        cw = last(bs, "v_cap_w", 0)
        ch = last(bs, "v_cap_h", 0)
        rw = last(bs, "v_rx_w", 0)
        rh = last(bs, "v_rx_h", 0)
        qual = last(bs, "v_quality", 0)
        qlvl = last(bs, "v_q_level", 0)
        qdowns = last(bs, "v_q_downs", 0)

        vis_line1 = (f"  VISUALS   fps enc {enc_fps:.0f} / dec {dec_fps:.0f}"
                     f"  ·  bitrate p50 {mbps_med:.2f} Mbps (peak {mbps_max:.2f})"
                     f"  ·  {bpf_med:.0f} B/frame (peak {bpf_max:.0f})"
                     f"  ·  cap {cw}x{ch} rx {rw}x{rh}"
                     f"  ·  q {qual:.2f} (lvl {qlvl}, downs {qdowns})")
        print(vis_line1)

        fmax = max(series(bs, "v_freeze_ms_max")) if series(bs, "v_freeze_ms_max") else 0
        f150 = last(bs, "v_freezes_150", 0)
        f400 = last(bs, "v_freezes_400", 0)
        flost = last(bs, "v_frames_lost", 0)
        fdrops = last(bs, "v_partial_drops", 0)
        dfails = last(bs, "v_dec_fails", 0)
        repkeys = last(bs, "v_repair_keys", 0)

        ipi_50_s = series(bs, "v_ipi_ms_p50")
        ipi_95_s = series(bs, "v_ipi_ms_p95")
        ipi_99_s = series(bs, "v_ipi_ms_p99")
        ipi_str = ""
        if ipi_50_s:
            ipi_50 = statistics.median(ipi_50_s)
            ipi_95 = statistics.median(ipi_95_s) if ipi_95_s else 0
            ipi_99 = statistics.median(ipi_99_s) if ipi_99_s else 0
            ipi_str = f"  ·  IPI p50 {ipi_50:.1f} p95 {ipi_95:.1f} p99 {ipi_99:.1f} ms"

        enc_lat_s = series(bs, "v_enc_ms_p50")
        dec_lat_s = series(bs, "v_dec_ms_p50")
        lat_parts = []
        if enc_lat_s:
            lat_parts.append(f"encLat {statistics.median(enc_lat_s):.1f} ms")
        if dec_lat_s:
            lat_parts.append(f"decLat {statistics.median(dec_lat_s):.1f} ms")
        lat_str = ("  ·  " + " ".join(lat_parts)) if lat_parts else ""

        loss_parts = []
        if flost > 0 or fdrops > 0 or dfails > 0 or repkeys > 0:
            loss_parts.append(f"lost frames {flost} (partial {fdrops}, decFails {dfails}, repairKeys {repkeys})")

        vis_line2 = (f"  FREEZES   max {fmax} ms  ·  >150ms: {f150}x  ·  >400ms: {f400}x"
                     + ipi_str + lat_str
                     + (("  ·  " + " ".join(loss_parts)) if loss_parts else ""))
        print(vis_line2)

    # ── AUDIO LOSS & JITTER ─────────────────────────────────────────────────
    played = last(bs, "played", 0)
    ctot = last(bs, "conceal_total", 0)
    cstarved = last(bs, "conceal_starved", 0)
    clost = last(bs, "conceal_lost", 0)
    late = last(bs, "late", 0)
    snaps = last(bs, "snaps", 0)
    snaps_b = last(bs, "snaps_behind", 0)
    snaps_p = last(bs, "snaps_past", 0)
    stalls = last(bs, "stalls", 0)
    cmax_s = series(bs, "a_conceal_ms_max")
    cmax_ms = max(cmax_s) if cmax_s else 0

    if played > 0 or ctot > 0 or late > 0 or snaps > 0:
        total_samples = played + ctot
        conc_pct = (ctot / total_samples * 100.0) if total_samples > 0 else 0.0
        starved_pct = (cstarved / total_samples * 100.0) if total_samples > 0 else 0.0
        lost_pct = (clost / total_samples * 100.0) if total_samples > 0 else 0.0

        audio_parts = [
            f"played {played} spls",
            f"conceal {conc_pct:.2f}% (starved {starved_pct:.2f}%, lost {lost_pct:.2f}%)",
            f"max run {cmax_ms:.1f} ms",
            f"late arrivals {late}",
            f"jitter snaps {snaps} ({snaps_b}b/{snaps_p}p)"
        ]
        if stalls > 0:
            audio_parts.append(f"audio stalls {stalls}")
        print(f"  AUDIO     " + "  ·  ".join(audio_parts))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: telemetry.py [local <path> | call | pairids <call> | recent]")
        sys.exit(1)
    mode = sys.argv[1]
    if mode == "local":
        bs = []
        for l in open(sys.argv[2], errors="replace"):
            l = l.strip()
            if not l: continue
            try:
                bs.append(json.loads(l))
            except Exception:
                pass
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
              f"{'rtt':>5} {'g2g':>5} {'fps':>4} {'vpn':>6} "
              f"{'mic%':>5} {'echo':>5} {'both':>5} {'choppy':>7} {'gaveway':>8}")
        for c in cs:
            t = datetime.datetime.fromtimestamp(c.get("startedAt", 0)).strftime("%H:%M:%S")
            rtt_val = c.get('rtt_ms')
            rtt = f"{rtt_val:.0f}" if isinstance(rtt_val, (int, float)) and rtt_val >= 0 else "-"
            g2g_val = c.get('g2g_p50')
            g2g = f"{g2g_val:.0f}" if isinstance(g2g_val, (int, float)) and g2g_val >= 0 else "-"
            fps_val = c.get('v_dec_ps')
            fps = f"{fps_val:.0f}" if isinstance(fps_val, (int, float)) and fps_val >= 0 else "-"
            vpn_c = c.get('vpn_relay_country')
            if not vpn_c and c.get('vpn_on'):
                vpn_c = "ON"
            vpn = (vpn_c if vpn_c else "dir")[:6]
            print(f"{c.get('call',''):>14} {c.get('install','')[:11]:>13} {c.get('version',''):>7} {t:>9} "
                  f"{c.get('durationS',0):>5} "
                  f"{rtt:>5} {g2g:>5} {fps:>4} {vpn:>6} "
                  f"{c.get('floor_held_pct',-1):>5.0f} {c.get('echo_corr',-1):>5.2f} "
                  f"{c.get('turn_collisions',-1):>5} {c.get('turn_flaps',-1):>7} {c.get('turn_yields',-1):>8}")
