/**
 * Live turn-taking analysis from a natural conversation.
 *
 * This replaces the scripted Q&A paradigm of `fatigue-lab/turns.js` with something
 * strictly better: measurement from a real conversation, with no script, no prompts,
 * and nothing for the participants to do. It works because two detectors run on each
 * machine — one on the local mic, one on the *received* audio — which makes two very
 * different numbers available from purely local timestamps.
 *
 * ── The two gaps, and why neither needs clock sync ───────────────────────────
 *
 *   HUMAN GAP  = my local onset − their arrival end
 *
 *     Both events are observed at my machine. Their audio already crossed the
 *     network to reach me, so the network delay is *inside* `arrival end`, not added
 *     to the difference. What's left is pure human response time — directly
 *     comparable to Boland's 297 ms face-to-face control, with no RTT correction and
 *     therefore no RTT estimation error.
 *
 *   PERCEIVED GAP = their arrival onset − my local end
 *
 *     Also both local. This one *does* contain a full round trip — my words had to
 *     reach them and their reply had to come back — which is correct, because it is
 *     what I actually experienced as silence. Comparable to Boland's 976 ms Zoom
 *     figure.
 *
 * The relationship `perceived ≈ human + RTT` therefore becomes a **consistency
 * check** rather than an assumption: we measure both independently and measure RTT
 * separately, and if they don't reconcile, something is wrong with the instrument
 * rather than with the conversation.
 *
 * ── Why events are reordered before use ──────────────────────────────────────
 * The state machine below reads chronology from event *order*, so it has to be fed in
 * chronological order — and the detector does not deliver in that order. An `onset`
 * arrives within about 5 ms of the sound that caused it; an `end` cannot be emitted
 * until HANG_MS of quiet has accumulated, so it arrives ~350 ms after the moment it
 * describes. Whenever a reply follows within that window, the reply's onset is
 * delivered *before* the previous turn's end.
 *
 * Delivered in that order, `them.speaking` is still true and `them.endAt` still points
 * at the turn before, so a clean 620 ms transition is recorded as a 16-second overlap.
 * Measured on a real fixture: every one of A's seven human transitions was destroyed
 * this way, leaving one usable gap of 2580 ms. The timestamps were already correct —
 * only the order was wrong, which is why the fix belongs here and not in the clock.
 *
 * So events go through a watermark buffer: hold each one until nothing older can still
 * arrive, then release in timestamp order. HOLD_MS is the delay this costs; it buys
 * correct chronology and costs nothing that matters, because this class measures the
 * conversation and is not in the media path.
 *
 * ── Collection policy ────────────────────────────────────────────────────────
 * Transitions are *flagged*, never dropped. Overlaps, backchannels, and long pauses
 * are all real conversational events and all interesting; deciding which ones count
 * as turn transitions is an analysis decision, and analysis happens offline where it
 * can be redone. The call happens once — record everything and argue later.
 *
 * Because the buffer lives here rather than in the caller, the live analyser and the
 * offline one see the same sequence: replaying a log in delivery order through this
 * class reproduces the live numbers exactly.
 */

// Anything below this is more likely a backchannel ("mm-hm", "yeah") than a turn.
// Flagged, not discarded.
const BACKCHANNEL_MS = 600;
// Beyond this, the silence is a lull or a topic change rather than a transition.
const LULL_MS = 3000;
// How long to hold an event before assuming nothing older will follow it. Must exceed
// the detector's worst backdating, which is HANG_MS (350 ms) for an `end`; 500 ms leaves
// slack for a tail that wobbles in and out of the quiet threshold.
const HOLD_MS = 500;

export class TurnTaking {
  constructor(onTransition) {
    this.onTransition = onTransition;

    // Watermark buffer — see the header. `lateEvents` counts events that arrived
    // already older than the release horizon, i.e. cases where HOLD_MS was not enough.
    // It is reported in the summary because a silent reordering is exactly the failure
    // this buffer exists to prevent, and it must not be able to hide.
    this.pending = [];
    // Newest timestamp *seen*, which is what sets the release horizon. Deliberately not
    // the newest released: the horizon has to advance as soon as a new event proves that
    // time has moved on, whether or not anything became releasable.
    this.maxT = -Infinity;
    // Newest timestamp actually handed to the state machine. `lateEvents` counts events
    // fed after something newer had already gone through — the precise definition of the
    // failure this buffer exists to prevent, rather than a proxy for it. An event that
    // arrives stale but whose successors are all still held is not counted, because
    // nothing went wrong: it is released in the right place anyway.
    this.lastFedT = -Infinity;
    this.lateEvents = 0;
    // Monotonic, so equal timestamps keep arrival order. It cannot be the buffer's
    // length: that shrinks on release, so sequence numbers would repeat and two events
    // sharing a timestamp could swap — which silently reintroduces the exact ordering
    // bug this buffer exists to fix.
    this.seq = 0;

    // Per-side speech state.
    this.local = { speaking: false, onsetAt: null, endAt: null, kind: null, lead: null };
    this.remote = { speaking: false, onsetAt: null, endAt: null, kind: null, lead: null };

    this.transitions = [];
    // Leads are kept per side, not merged, because the two answer different
    // questions. `local` is an instrument check — does my own mic and detector see
    // my own inhale at all. `remote` is the actual claim under test: their breath
    // survived capture, encoding, the network and my decoder, and reached me before
    // their words did. Merging them would let a healthy local figure paper over a
    // remote one that failed, which is precisely the result we most need to see.
    this.leads = { local: [], remote: [] };
  }

  /** Feed an event from the local-mic detector. */
  local_(ev, t) {
    return this.push('local', ev, t);
  }

  /** Feed an event from the received-audio detector. */
  remote_(ev, t) {
    return this.push('remote', ev, t);
  }

  /**
   * Accept an event and release everything that can no longer be overtaken.
   *
   * The horizon is derived from the newest timestamp seen rather than from a wall clock,
   * so replaying a log offline releases events at exactly the same points the live run
   * did. The consequence is that the last few events of a call stay buffered until
   * `flush()` — which is why `flush()` is not optional.
   */
  push(side, ev, t) {
    this.pending.push({ side, ev, t, seq: this.seq++ });
    if (t > this.maxT) this.maxT = t;
    this.release(this.maxT - HOLD_MS);
    return null;
  }

  release(horizon) {
    // Ties broken by arrival order: an onset and its classification can share a
    // timestamp, and the onset has to be processed first.
    this.pending.sort((a, b) => a.t - b.t || a.seq - b.seq);
    while (this.pending.length && this.pending[0].t <= horizon) {
      const p = this.pending.shift();
      // Out of order despite the buffer: HOLD_MS was too short for this call. Fed anyway
      // — dropping data is worse than reporting a caveat — but counted, because a silent
      // reordering is exactly the failure the buffer exists to prevent.
      if (p.t < this.lastFedT) this.lateEvents++;
      else this.lastFedT = p.t;
      this.feed(p.side, p.ev, p.t);
    }
  }

  /** Release everything still held. Call before reading the final summary. */
  flush() {
    this.release(Infinity);
  }

  feed(side, ev, t) {
    const me = side === 'local' ? this.local : this.remote;
    const them = side === 'local' ? this.remote : this.local;

    if (ev.type === 'onset') {
      me.speaking = true;
      me.onsetAt = t;
      me.kind = null;
      me.lead = null;

      // A turn transition: they stopped, then I started. `them.endAt` is set only
      // when their side has actually ended, so an overlap (them still speaking)
      // leaves endAt stale — hence the explicit overlap flag rather than trusting
      // the arithmetic.
      if (them.endAt !== null) {
        const gap = t - them.endAt;
        const overlap = them.speaking;
        this.record({
          // `local` onset after `remote` end is the HUMAN gap (no network in it).
          // `remote` onset after `local` end is the PERCEIVED gap (contains RTT).
          metric: side === 'local' ? 'human' : 'perceived',
          responder: side,
          gapMs: +gap.toFixed(1),
          overlap,
          priorUtteranceMs: them.onsetAt !== null ? +(them.endAt - them.onsetAt).toFixed(1) : null,
          backchannel: them.onsetAt !== null && them.endAt - them.onsetAt < BACKCHANNEL_MS,
          lull: gap > LULL_MS,
          negative: gap < 0,
        });
      }
    } else if (ev.type === 'classified') {
      me.kind = ev.kind;
      // Attach the opening cue to the transition we just recorded, if any. The
      // classification arrives ~35 ms after the onset, so it cannot be known at
      // record time — this is why the field is patched rather than passed.
      const last = this.transitions[this.transitions.length - 1];
      if (last && last.responder === side && last.openedWith == null) {
        last.openedWith = ev.kind;
        this.onTransition?.(last, 'update');
      }
    } else if (ev.type === 'voiced') {
      me.lead = ev.leadMs;
      this.leads[side].push(ev.leadMs);
      const last = this.transitions[this.transitions.length - 1];
      if (last && last.responder === side && last.breathLeadMs == null) {
        last.breathLeadMs = +ev.leadMs.toFixed(1);
        // The gap to the first *word*, as distinct from the gap to first evidence.
        // Both are real; the design's argument is precisely that everyone else only
        // reports the second one.
        last.gapToWordMs = +(last.gapMs + ev.leadMs).toFixed(1);
        this.onTransition?.(last, 'update');
      }
    } else if (ev.type === 'end') {
      me.speaking = false;
      me.endAt = t;
    }
    return null;
  }

  record(tr) {
    tr.n = this.transitions.length + 1;
    tr.openedWith = null;
    tr.breathLeadMs = null;
    tr.gapToWordMs = null;
    this.transitions.push(tr);
    this.onTransition?.(tr, 'new');
  }

  /**
   * Live summary. `clean` applies the filters an analyst would apply — but the
   * underlying array keeps everything, so a different filter can be applied later.
   */
  summary() {
    const clean = this.transitions.filter((t) => !t.negative && !t.overlap && !t.lull && !t.backchannel);
    const human = clean.filter((t) => t.metric === 'human').map((t) => t.gapMs);
    const perceived = clean.filter((t) => t.metric === 'perceived').map((t) => t.gapMs);
    const wordGaps = clean.filter((t) => t.gapToWordMs != null).map((t) => t.gapToWordMs);

    // Breath rate is computed per responder for the same reason leads are kept per
    // side: a `remote` rate near zero with a healthy `local` rate is the single most
    // diagnostic result this instrument can produce — it would mean the inhale is
    // being captured but destroyed in transit, which is a transport finding, not a
    // human one.
    const rate = (side) => {
      const set = clean.filter((t) => t.responder === side);
      return set.length ? +((set.filter((t) => t.openedWith === 'breath').length / set.length) * 100).toFixed(0) : null;
    };

    return {
      total: this.transitions.length,
      usable: clean.length,
      humanMedian: median(human),
      humanN: human.length,
      perceivedMedian: median(perceived),
      perceivedN: perceived.length,
      wordGapMedian: median(wordGaps),
      // `remote` is the number the design is claiming. `local` is the control.
      leadMedian: median(this.leads.remote),
      leadN: this.leads.remote.length,
      leadMedianLocal: median(this.leads.local),
      leadNLocal: this.leads.local.length,
      breathRate: rate('remote'),
      breathRateLocal: rate('local'),
      discarded: {
        negative: this.transitions.filter((t) => t.negative).length,
        overlap: this.transitions.filter((t) => t.overlap).length,
        lull: this.transitions.filter((t) => t.lull).length,
        backchannel: this.transitions.filter((t) => t.backchannel).length,
      },
      // Non-zero means HOLD_MS was too short for this call and some transitions were
      // still assembled out of order. Anything above a handful invalidates the gaps.
      lateEvents: this.lateEvents,
      pendingAtSummary: this.pending.length,
    };
  }
}

export function median(xs) {
  if (!xs?.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return +(s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2).toFixed(1);
}
