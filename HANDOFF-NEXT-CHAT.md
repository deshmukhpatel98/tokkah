I'm working on **Kin** — a native macOS calling app (repo `~/Downloads/video calling`,
public at github.com/deshmukhpatel98/tokkah, AGPL). Currently shipped: **0.92.0**,
live on both my Macs.

**How I work — please follow these without being asked:**
- When work is finished, cut the release and verify it on the live deployment
  yourself. Don't ask permission to ship.
- I test on two real Macs, side by side. Don't build rig-based tests to prove a
  fix works on a call — verify from the telemetry of a real call I make.
- Talk to me in ~3-4 lines of plain language, outcome first. Keep the numbers.

**Read the telemetry — never debug a call from a log again:**
```
mac/tools/telemetry.sh recent 10        # last calls, both ends, one line each
mac/tools/telemetry.sh pair <call-id>   # a call AND the other end of it
mac/tools/telemetry.sh local            # this Mac's own copy, no network
```
The key is at `~/.config/tokkah/dash.env`. Read the echo **peak**, never the last
value. Every call also writes `~/Library/Logs/Kin/beats.ndjson` locally.

**What I want next: turn-taking latency.** Time-to-audible is already 0 ms (the
floor is taken locally, no round trip). What's left is thresholds:
- `releaseMs` 450 ms — how long the holder must be quiet before the turn is free
- `playoutTailMs` 150 ms — the idle echo guard's speaker tail
- The **big win, not yet done**: the turn-end predictor's *far-end* half. 0.92.0
  wired the local half (my transcript releases my own turn early). The other half
  — sending that number across the wire beside the vocal byte so my mic is already
  open *before* the other person finishes — needs a protocol change in Net.swift.
  See the long comment above `turnEndingSoon` in Subtitles.swift, which explains it.

**Under test right now (I'll make a call and you read the numbers):** the echo.
0.84.0 fixed a mic recording 5x too loud; 0.90.0 found the real remaining cause —
the floor's `idle` state (nobody's turn, reached 450 ms after any pause, ~40% of a
call) left both mics open next to both live speakers. 0.91.0 corrected a hole in
that fix. 0.92.0 made all of it countable: look at `echo_guard_pct` vs
`echo_guard_idle_pct` — if the guard never fired, that's a different bug from it
firing and not helping.

**Standing hazards in this codebase, learned the hard way:**
- A metric that can't see the failure returns the same value as a pass. Every new
  arm needs a case it must REJECT, and check it fails when the fix is disabled.
- `floor: yours N%` is misnamed — it counts the local voice gate, not the floor.
- Loopback rigs on one Mac cannot measure echo; both ends share the speaker.
- Pushing to GitHub needs `gh auth switch --user deshmukhpatel98`.

Start by reading `MEMORY.md` in your memory directory — the traps are all written up.
