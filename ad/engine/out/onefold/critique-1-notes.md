{
  "notes": [
    {
      "shot": "S6",
      "severity": 3,
      "note": "The return bend resolves into two 30 px discs: at 1080p that is a speck, and the mark it becomes cannot be read on a phone. The bend itself now reads (a hairpin with a long tail) but the tail runs off to the right and leaves the composition unbalanced.",
      "fix": "Keep the hairpin at (610,610) r 80 exactly as written. Over the last 1800 ms of the shot, let the contour shorten from both ends and gather into TWO discs of radius 110 centred at (890,470) amber (A) and (1030,470) ink, with a soft shared halo of 160 px (use lib.mark with r 110, sep 70, cx 960, cy 470; alphaInk 0.88, alphaAccent 0.74, overlap 0.14). Hand off exactly those discs."
    },
    {
      "shot": "S7",
      "severity": 3,
      "note": "The brand reveal is too small to be a reveal: two 30 px discs and an 88 px wordmark floating in a black frame. The discs must be the mark, not a detail.",
      "fix": "Draw the mark with lib.mark(light, 960, 470, 110, 70, 0.88, 0.74, 0.14, 1) every frame (the exact discs S6 hands off), breathing at most 0.3%. Set the wordmark with dom.wordmark('Onefold', {size: 152, top: 618, alpha}) rising over 800 ms from c.shot.start + 0.4 (8 px rise). Keep the sans feel by leaving letter-spacing default; do not use lib.text for the name. Contract the halo over 600 ms as written. Hand off: the mark at (960,470) r 110 and the wordmark at top 618."
    },
    {
      "shot": "S8",
      "severity": 3,
      "note": "The end card drops to a single small line and the mark shrinks to nothing; the ending must hold the identity at full weight and read at contact-sheet size.",
      "fix": "Keep lib.mark at (960,470) r 110 sep 70 unchanged; keep dom.wordmark('Onefold', {size: 152, top: 618, alpha: 1}); bring 'Send back. Run again.' in with dom.tagline(text, {size: 56, top: 800, alpha}) over 600 ms from c.shot.start + 0.3. Hold everything still until the last 0.8 s, then fade all to ground (multiply every alpha by 1 - lib.span(c.t, c.D - 0.8, c.D, lib.linear)). No URL, no button."
    }
  ],
  "rewrite": [
    "S6",
    "S7",
    "S8"
  ],
  "verdict": "director's notes"
}