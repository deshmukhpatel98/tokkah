I'm working on **Kin** — a native macOS calling app (repo `~/Downloads/video calling`,
public at github.com/deshmukhpatel98/tokkah, AGPL). Currently shipped: **0.93.0**,
live on both my Macs after they pick up the update.

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

**Shipped in 0.93.0:** the turn-end predictor's far-end half. Their number rides
the pad byte beside the vocal status, so this mic can be open before they finish.
On a live call look at `predict_far_releases` / `predict_far_saved_ms` vs
`predict_peer_p_peak` — zero peak on a 0.93 call where they talked means the
byte never arrived; a high peak and zero far-releases means the floor didn't
use it.

**Still under test:** the echo (idle guard from 0.90–0.92). Look at
`echo_guard_pct` vs `echo_guard_idle_pct`. If the guard never fired, that's a
different bug from it firing and not helping.

**Standing hazards in this codebase, learned the hard way:**
- A metric that can't see the failure returns the same value as a pass. Every new
  arm needs a case it must REJECT, and check it fails when the fix is disabled.
- `floor: yours N%` is misnamed — it counts the local voice gate, not the floor.
- Loopback rigs on one Mac cannot measure echo; both ends share the speaker.
- Pushing to GitHub needs `gh auth switch --user deshmukhpatel98`.

Start by reading `MEMORY.md` in your memory directory — the traps are all written up.
