"""Reads what tools/telemetry.sh fetches. Prints the numbers a call is judged on
rather than the whole beat: a 80 KB JSON dump is data nobody looks at twice."""
import json, sys, datetime

def num(b, k, d=None):
    v = b.get(k)
    return v if isinstance(v, (int, float)) else d

def series(bs, k):
    return [v for v in (num(b, k) for b in bs) if v is not None]

def call_summary(bs, label=""):
    if not bs:
        print("  no beats"); return
    ec, fp = series(bs, "echo_corr"), series(bs, "floor_held_pct")
    out = []
    # The PEAK, not the last value. echo_corr is an instant: the final beat of a
    # call that reached 0.71 read 0.04, so the summary said "no echo" about a
    # call with a measured one.
    if ec:
        over = sum(1 for x in ec if x > 0.45)
        out.append(f"echo peak {max(ec):.2f} (over 0.45 in {over}/{len(ec)} beats, last {ec[-1]:.2f})")
    if fp: out.append(f"mic open {sorted(fp)[len(fp)//2]:.0f}%")
    for k, name in (("turn_collisions", "both talking"), ("turn_flaps", "choppy"),
                    ("turn_yields", "gave way")):
        s = series(bs, k)
        if s: out.append(f"{name} {max(s)}")
    print("  " + "  ·  ".join(out))

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
