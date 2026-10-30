# Existing Gen 3 → MkII preset converters

Surveyed 2026-10-28 (web, GitHub, SourceForge; forums only through search snippets).

No open-source tool converts a Gen 3 `.tsl` straight into a MkII `.tsl`.

| Tool | Licence | Relevance | Status |
|---|---|---|---|
| [Katana GO FxFloorBoard](https://sourceforge.net/projects/fxfloorboard/files/KatanaFxFloorBoard/Katana%20FxFloorBoard%20for%20GO%20Desktop/) (gumtown) | GPL | Opens Gen 3 `.tsl` and saves MkII `.tsl` — a two-hop Gen 3 → GO → MkII path usable from its UI | Verified in its source (2025-08). Lossy (5-voice GO amp model, colour 1 only for booster/reverb, selected colour ignored); likely reads the wrong Gen 3 FX/Delay 2 blocks |
| [Katana MK2 FxFloorBoard](https://sourceforge.net/projects/fxfloorboard/files/KatanaFxFloorBoard/Katana%20FxFloorboard%20for%20MK2%20Desktop/) (gumtown) | GPL | Its readme claims Gen 3 file import/export in builds of 2026-01-08 — would be the direct converter | Unverified: the published source (2024-05) has no Gen 3 code |
| [cordfuse/toneai-katana-web](https://github.com/cordfuse/toneai-katana-web) | MIT | Converts MkII ↔ Gen 3 at a "tone intent" level; parameter tables for both, an amp-character map (Gen 3 PUSHED → MkII VO Drive), a MkII writer | Partial; its own notes flag doubtful booster/reverb values |
| [jpbarraca/katatone](https://github.com/jpbarraca/katatone) | Apache-2.0 | Gen 3 editor with a documented Gen 3 address map incl. colour variations | Gen 3 only |
| [mathieu-lemay/katana-tsl-parser](https://github.com/mathieu-lemay/katana-tsl-parser) | MIT | Typed MkII `.tsl` read/write | Partial |
| Katana Librarian (Apps For Amps) | proprietary | Imports/exports MkI, MkII, Gen 3 and GO `.tsl` | Gen 3 → MkII conversion undocumented |

Also looked at: [Solrak97/ToneForge](https://github.com/Solrak97/ToneForge) and
[Splatink/rusty-boss](https://github.com/Splatink/rusty-boss) (Gen 3 only, refuse MkII files),
[dogakocak/boss-katana-mcp](https://github.com/dogakocak/boss-katana-mcp),
[s4mdf0o1/TuxKatana](https://github.com/s4mdf0o1/TuxKatana) (AGPL),
[fpereira3/ktnacontrol](https://github.com/fpereira3/ktnacontrol) (no licence). No forum thread describes a hand
conversion.

**Block check on `GREEN BASKET.tsl`:** six `FX` and six `DELAY` blocks but three `BOOSTER` and `REVERB` blocks — two
slots × three colours — which supports katatone's reading (FX 1–3 = MOD, FX 4–6 = FX, DELAY 4–6 = Delay 2) over
FxFloorBoard's. To be confirmed on a Gen 3 amp.

**Starting point for our own converter:** first try the 2026-01-08 MK2 FxFloorBoard build on `GREEN BASKET.tsl`; if the
claim holds, the problem is solved. Otherwise use the MIT/Apache tables above as references and keep GPL code out.
