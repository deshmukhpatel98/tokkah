{
  "notes": [
    {
      "shot": "S3",
      "severity": 3,
      "note": "The upgrade close-up is missing. Our isolated box occupies roughly half the reference product width, and neither the descending chip nor its interaction is visible.",
      "fix": "At the sampled upgrade moment, increase projected product width from approximately 810 to 1620 px; centre x=960, top y=565, allowing the bottom to crop. Add a descending upgrade chip approximately 360×350 px, centred at [975,365], with a stylised hand entering from above. Preserve the same product mesh through the upgrade."
    },
    {
      "shot": "S14",
      "severity": 3,
      "note": "The ending is broken: our black-phase sample retains a dim mark and unreadable wordmark; the final sample returns to grey instead of holding black with legal.",
      "fix": "Force an opaque #000000 background from 37.95 through 43.02 s and clear logo/wordmark layers at 37.95 s. Show legal from 38.4 through 43.0 s inside [430,1004,1485,1031], with 23 px glyph height and #777777 text. Do not fade back to the studio background."
    },
    {
      "shot": "S12",
      "severity": 3,
      "note": "Our lockup sample is product-only where the reference already has its headline. The product width is close, but its foreshortened silhouette does not fill the measured near-square box.",
      "fix": "At 1920×1080, fit the product projection to [832,440,1205,797] without changing its physical proportions. Reveal 'The Mighty' from 33.6 s at x=90–643, capTop=490, baseline=571, capHeight=81. Complete 'Pebble' by 34.2 s at x=1344–1773, capTop=492, baseline=573, capHeight=81; centre 'with M6' within [1452,602,1661,645]. Use #111111, hold through 35.7 s, and remove text with the product by 36.0 s."
    },
    {
      "shot": "S9",
      "severity": 3,
      "note": "The rocket vignette is a small horizontal box with two pods. The reference is a tall, densely built launch assembly occupying almost the entire frame height.",
      "fix": "Increase assembly height from approximately 520 to 1060 px and width to 1310 px; centre it at [960,530]. Present Pebble's square top toward camera in an upright carrier, retaining the original mesh. Add four side boosters and three lower exhaust nozzles around it rather than replacing the hero."
    },
    {
      "shot": "S3",
      "severity": 3,
      "note": "The shared studio treatment is too bright and the hero is gold rather than aluminium. Shadows are too faint and short to reproduce the reference's grounding. Existing plain top, foot ring and power light should be retained.",
      "fix": "In the shared product/stage settings, set body dimensions to [1.97,0.5,1.97] m, corner radius=0.16 m, neutral aluminium base #bfc1c5, metallic=0.8 and roughness=0.3. Use ground #b6b8bd and adjust exposure until rendered ground luminance is 170±5. Set the sweep horizon to y=620. Keep an upper-left key; target a lower-right shadow displacement of approximately [250,170] px with 70 px softness at 1920×1080."
    }
  ],
  "rewrite": [
    "S3",
    "S9",
    "S12",
    "S14"
  ],
  "keep": [
    "S1"
  ],
  "verdict": "Sampled vignettes are distinct, but upgrade framing, rocket scale, studio values and end cards miss the reference. Exact cut rhythm needs moving-picture review."
}