{
  "notes": [
    {
      "shot": "S1",
      "severity": 3,
      "note": "The opening shoe occupies approximately 22% of frame height, not the required 60%. Similar undersizing makes material detail disappear throughout the samples.",
      "fix": "Increase S1's visible shoe height to 648px at 1920×1080; center at (960,540), with width capped at 1728px. Resolve knit detail at an 8–12px pitch."
    },
    {
      "shot": "S1",
      "severity": 3,
      "note": "The tall collar, short forefoot and thick sole read more like a slipper than a low-profile road-running shoe.",
      "fix": "Revise lib.product once for every instance: lower collar height 20%, lengthen forefoot 15% and reduce sole thickness 20%. Preserve the continuous amber construction, rounded heel and single fold line; add zero separate logos."
    },
    {
      "shot": "S5",
      "severity": 3,
      "note": "The wear-threshold sample still presents a clean, hovering shoe. Its pose and scale repeat neighbouring product views rather than introducing deterioration.",
      "fix": "Set shoe height to 648px and rotation to -12°. Reveal a wear overlay across 35% of the upper and 25% of the outsole during 15.42–15.74s. Sweep a 6px light along the existing fold line during 17.20–17.52s; do not deform the shoe."
    },
    {
      "shot": "S9",
      "severity": 3,
      "note": "The 'Again.' frame shows another small single shoe, not the reconstructed pair. It closely repeats the preceding single-shoe sample.",
      "fix": "Replace the single with two lib.product instances: foreground height 648px, rear height 518px, rear offset (-230,-110)px. Keep both inside 96px horizontal safe margins. Reveal the rear shoe during 29.10–29.42s and sweep a 6px fold-line highlight during 29.42–29.74s. Remove 'Again.'"
    },
    {
      "shot": "S13",
      "severity": 3,
      "note": "The final sample is effectively blank. Neither product, Onefold wordmark nor invitation is readable.",
      "fix": "Show a 648px-high shoe centered at (960,540). Set 'Onefold' in 144px cream type centered at (960,132), and 'Your next pair starts here.' in 72px type centered at (960,972). Complete the reveal by 43.02s, run a 320ms fold-line sweep, and hold everything through 45.00s without fading to black."
    }
  ],
  "rewrite": [
    "S1",
    "S5",
    "S9",
    "S13"
  ],
  "keep": [
    "S6",
    "S10"
  ],
  "verdict": "Palette and drawer metaphor work, but undersized, repetitive shoes and a blank ending undermine product recognition and the circular story."
}