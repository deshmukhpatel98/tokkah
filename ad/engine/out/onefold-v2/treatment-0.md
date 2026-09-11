TREATMENT

**Tension.** The run is finished, but the shoes stay in your drawer because throwing them away still feels wrong.

**Idea.** Don’t escape the shoe’s ending; show it becoming another beginning.

**Appearance.** Onefold has a low-profile road-running form; a continuous knit upper flowing into a same-material sole; warm sand-amber colour; a soft, rounded heel; a subtle heel-to-toe fold line; and no separate logo. One shared layered SVG, `lib.product`, supplies every shoe instance, including worn states.

**Motif.** Light travels *inside the fold line*, never around the shoe as a recycling symbol. It returns at 0 seconds as a cold discovery, 8 as the warm hero reveal, 16 during a road landing, 30 as material forms the next pair, and 41 as a settled promise. These are its only animated appearances.

Everything is designed for 1920×1080. Cream typography stays sparse; cold blue belongs to accumulation, amber to the product. Transformations are visibly drawn, not presented as documentary manufacturing. Recognisable shoes remain visible for over 40 seconds. The narration supplies the argument; pictures supply physical evidence.

**Narration — 99 words**

L1 · 0.40–3.55: You keep them. Throwing them away still feels wrong.  
L2 · 4.20–7.35: Another finished pair. Another thing you cannot quite bin.  
L3 · 8.20–11.35: This is Onefold. A road running shoe made differently.  
L4 · 12.20–15.35: One material, from the upper right through the sole.  
L5 · 16.20–19.35: Made for the road. For your next morning run.  
L6 · 20.20–23.35: And all the miles that wear your shoes out.  
L7 · 24.20–27.35: When that happens, send your worn out pair back.  
L8 · 28.10–29.50: Not to the drawer.  
L9 · 30.10–33.25: That same material becomes the next pair of Onefolds.  
L10 · 34.20–37.35: So the end of this pair starts the next.  
L11 · 38.15–40.60: Your old shoes have somewhere to go.  
L12 · 41.20–43.65: Onefold. Wear them out. Send them back.

**Score.** At 120 BPM, a tight running pulse places every cut on a beat. An unresolved minor interval opens into a restrained, warm suspended chord. Dry clicks, low felted bass and glassy taps gradually yield to woody percussion.

**Voice.** George: British, warm and close, with brisk conversational attack; recognise the guilt without dwelling on it, then become quietly certain.

PLAN
{
  "product": "Onefold single-material running shoe",
  "tension": "Finished shoes accumulate because throwing them away feels wrong.",
  "idea": "Show the worn shoe becoming the next pair.",
  "tagline": "Wear them out. Send them back.",
  "wordmark": "Onefold",
  "tempo": "fast",
  "palette": {
    "ground": "#05060a",
    "ink": "#f3f1ec",
    "accentA": "#d9a35b",
    "accentB": "#729bc9"
  },
  "productDescription": {
    "form": "Low-profile road runner",
    "material": "Continuous knit upper and sole, one material throughout",
    "colour": "Warm sand-amber",
    "details": [
      "Soft rounded heel",
      "Subtle heel-to-toe fold line",
      "No separate logo"
    ]
  },
  "motif": {
    "name": "The fold carries on",
    "description": "A narrow gradient highlight travels inside the product's fold line in 500ms; the underlying fold remains static elsewhere.",
    "returns": [
      "S1",
      "S3",
      "S5",
      "S9",
      "S12"
    ]
  },
  "voice": {
    "voice_id": "JBFqnCBsd6RMkjVDRZzb",
    "voice_name": "George",
    "stability": 0.5,
    "direction": "Brisk, intimate British warmth; recognition first, quiet certainty next."
  },
  "voiceover": [
    {
      "t": 0.4,
      "text": "You keep them. Throwing them away still feels wrong."
    },
    {
      "t": 4.2,
      "text": "Another finished pair. Another thing you cannot quite bin."
    },
    {
      "t": 8.2,
      "text": "This is Onefold. A road running shoe made differently."
    },
    {
      "t": 12.2,
      "text": "One material, from the upper right through the sole."
    },
    {
      "t": 16.2,
      "text": "Made for the road. For your next morning run."
    },
    {
      "t": 20.2,
      "text": "And all the miles that wear your shoes out."
    },
    {
      "t": 24.2,
      "text": "When that happens, send your worn out pair back."
    },
    {
      "t": 28.1,
      "text": "Not to the drawer."
    },
    {
      "t": 30.1,
      "text": "That same material becomes the next pair of Onefolds."
    },
    {
      "t": 34.2,
      "text": "So the end of this pair starts the next."
    },
    {
      "t": 38.15,
      "text": "Your old shoes have somewhere to go."
    },
    {
      "t": 41.2,
      "text": "Onefold. Wear them out. Send them back."
    }
  ],
  "score": {
    "bpm": 120,
    "harmony": "Unresolved minor interval opens into a warm suspended chord.",
    "timbres": "Dry clicks, felted bass, glass taps, woody percussion.",
    "beats": [
      {
        "t": 8,
        "what": "Warm chord opens"
      },
      {
        "t": 28,
        "what": "Dry pulse doubles"
      },
      {
        "t": 41,
        "what": "Home note lands"
      }
    ]
  },
  "duration": 45,
  "shots": [
    {
      "id": "S1",
      "start": 0,
      "end": 4,
      "title": "Still In Here",
      "direction": "Across 0–4s, worn lib.product instances fill a shallow SVG drawer, each 660×330px. Cold B light traces one fold in 500ms at onset; at 2s, a foreground drawer edge drops, revealing another buried toe. Carries L1.",
      "handoffIn": "Cold drawer fills frame",
      "handoffOut": "One toe remains exposed",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S2",
      "start": 4,
      "end": 8,
      "title": "One More Pair",
      "direction": "Across 4–8s, the exposed lib.product rises from the stack, reaching 800×400px through a 600ms camera push. Cold drawer shadows remain; at 6s, an amber side-light reveals its worn knit without changing geometry. Carries L2.",
      "handoffIn": "Exposed toe anchors composition",
      "handoffOut": "Isolated shoe faces camera",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S3",
      "start": 8,
      "end": 12,
      "title": "Meet The Material",
      "direction": "At 8s, snap-zoom for 300ms into a fresh lib.product, 1520×760px through 12s: the HERO occupies 70% frame height. Amber fold light travels for 500ms; at 10s, cream grazing illumination exposes knit and rounded heel. Carries L3.",
      "handoffIn": "Shoe silhouette matches cut",
      "handoffOut": "Lit knit fills view",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S4",
      "start": 12,
      "end": 16,
      "title": "Nothing To Separate",
      "direction": "Across 12–16s, lib.product holds 1320×660px while a 650ms camera pan follows continuous material from upper into sole. Amber grazing light reveals uninterrupted construction; at 14s, two tiny cream endpoint dots appear without dividing the shoe. Carries L4.",
      "handoffIn": "Upper texture dominates",
      "handoffOut": "Sole meets lower edge",
      "copy": "No mix.",
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S5",
      "start": 16,
      "end": 20,
      "title": "Back To Running",
      "direction": "Across 16–20s, lib.product remains 980×490px above drawn road ticks. A 550ms landing compresses its shadow; amber fold light answers in 500ms. At 18s, another road stripe enters under the toe, renewing forward momentum. Carries L5.",
      "handoffIn": "Sole becomes road contact",
      "handoffOut": "Road streams beneath shoe",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S6",
      "start": 20,
      "end": 24,
      "title": "Miles Leave Marks",
      "direction": "Across 20–24s, lib.product stays 1000×500px as road ticks accelerate through a 600ms whole-scene pan. Neutral grazing light reveals wear stippling at onset; at 22s, sole scuffs appear, preserving the same warm material and silhouette. Carries L6.",
      "handoffIn": "Running angle continues",
      "handoffOut": "Worn shoe settles forward",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S7",
      "start": 24,
      "end": 28,
      "title": "One Quiet Move",
      "direction": "Across 24–28s, worn lib.product stays visible at 880×440px inside an open, cream-stroked return parcel. A 600ms lateral camera move leaves the cold drawer behind; at 26s, the parcel gains an amber interior light. Carries L7.",
      "handoffIn": "Worn shoe matches position",
      "handoffOut": "Open parcel frames shoe",
      "copy": "RETURN",
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S8",
      "start": 28,
      "end": 30,
      "title": "Keep Material Moving",
      "direction": "Across 28–30s, lib.product separates into its own amber SVG knit layers over 700ms, retaining an 800×400px residual silhouette. Parcel edges cut away at onset; cold B light disappears while warm material remains visibly accounted for. Carries L8.",
      "handoffIn": "Parcel holds worn material",
      "handoffOut": "Amber layers retain silhouette",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S9",
      "start": 30,
      "end": 34,
      "title": "Same Material Again",
      "direction": "Across 30–34s, those same layers reform lib.product at 1200×600px in 650ms, following the illuminated fold. Warm light reveals fresh knit; at 32s, a second instance emerges from the remaining material, completing the next pair. Carries L9.",
      "handoffIn": "Loose layers preserve position",
      "handoffOut": "Fresh pair shares light",
      "copy": "AGAIN",
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S10",
      "start": 34,
      "end": 38,
      "title": "Next Starts Here",
      "direction": "Across 34–38s, two lib.product instances remain 840×420px each, fresh and road-ready. A 600ms camera pan brings road markings underneath; at 36s, the leading shoe lifts against a warm gradient, exchanging the parcel world for running. Carries L10.",
      "handoffIn": "Fresh pair retains spacing",
      "handoffOut": "Leading shoe points forward",
      "copy": null,
      "primitive": "shape",
      "params": {}
    },
    {
      "id": "S11",
      "start": 38,
      "end": 41,
      "title": "Name The Change",
      "direction": "Across 38–41s, lib.product remains 520×260px below the cream Onefold wordmark, revealed at onset. A 500ms pullback clears generous space under warm top-light; at 40s, a road stroke enters beneath the shoe without becoming a symbol. Carries L11.",
      "handoffIn": "Forward shoe anchors mark",
      "handoffOut": "Wordmark rests above product",
      "copy": null,
      "primitive": "mark",
      "params": {}
    },
    {
      "id": "S12",
      "start": 41,
      "end": 45,
      "title": "Make Another Beginning",
      "direction": "From 41–44.7s, lib.product holds 900×450px beneath Onefold and the new CTA. Its amber fold settles through a 500ms light pass; at 43s, cream road ticks enter. Warm illumination persists until the final 300ms fade. Carries L12.",
      "handoffIn": "Brand and shoe persist",
      "handoffOut": "Final frame reaches black",
      "copy": "Start your next miles.",
      "primitive": "cta",
      "params": {}
    }
  ]
}