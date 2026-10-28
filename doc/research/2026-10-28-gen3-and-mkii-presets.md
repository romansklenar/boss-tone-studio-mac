# KATANA Gen 3 and MkII presets

Researched 2026-10-28, for: why a preset made on a KATANA Gen 3 cannot be imported into the MkII editor, and whether a
converter is feasible. Samples: `GREEN BASKET.tsl` (made on a Gen 3) and `FOOVERLONG.tsl` (made on a MkII), the user's
own files.

## What Roland says

- The BTS for KATANA Gen 3 manual (p. 8) says the Gen 3 editor imports livesets created on earlier KATANA models
  ([PDF](https://static.roland.com/assets/media/pdf/BTS_KTN3_PC_eng02_W.pdf)); the KATANA Gen 3 product page lists
  compatibility with sounds created on previous models
  ([boss.info](https://www.boss.info/global/products/katana-50_gen_3/features/)).
- No official statement covers Gen 3 → MkII. The MkII editor (2.1.0) predates Gen 3 and only knows MkII files and
  original KATANA (MkI) files.

## Observed

- Importing `GREEN BASKET.tsl` into the MkII editor shows "UNSUPPORTED DATA — The file is not supported on KATANA MkII";
  `FOOVERLONG.tsl` imports fine.
- Roland's Gen 3 editor for macOS (1.1.0) is a universal app (x86_64 + arm64), so Gen 3 owners already have a native
  editor; serving it from this project would add little.

## The `.tsl` format

Both generations use the same envelope:
`{"name", "formatRev", "device", "data": [[{"memo", "paramSet": {"<block>": ["2-digit hex", …]}}]]}` with up to 15
patches.

| | MkII (`FOOVERLONG`) | Gen 3 (`GREEN BASKET`) |
|---|---|---|
| `device` | `KATANA MkII` | `KATANA Gen3` |
| `formatRev` | `0002` | `0000` |
| Blocks per patch | 31, prefix `UserPatch%` | 80, prefix `PATCH%` |
| Block names in common | none | none |

The key structural difference is the colour variations (Green/Red/Yellow):

- **MkII**: each effect slot stores a *type* per colour, but all colours share one parameter set (one booster block,
  `Fx(1)`/`Fx(2)` for MOD/FX, `Delay(1)`/`Delay(2)` for Delay/Delay 2, one reverb set).
- **Gen 3**: each colour has its own parameter block — `BOOSTER(1–3)`, `REVERB(1–3)`, and six each of `FX`/`FX_DETAIL`
  and `DELAY` (two slots × three colours) — plus a `COLOR` block with the selected colour per effect.

Other differences: Gen 3 has fewer amp types plus a variation switch (MkII has many more types), two Gen 3-only effect
chain orders, a different layout for knob/pedal assigns, and some MkII-only fields (e.g. preamp gain on a 0–120 scale,
bright).

## Is a Gen 3 → MkII converter feasible?

Yes, with known losses:

| Gen 3 | MkII | Loss |
|---|---|---|
| Patch name, EQ, solo, pedal FX, noise suppressor, send/return, contour, switches | same fields | none (re-encoded where sizes differ) |
| Effect types per colour | types per colour | none |
| Booster, Delay, Reverb settings per colour | one shared set | yes, when colours differ — keep the selected colour (or Green) |
| MOD/FX settings per colour | one shared set covering all types | only when two colours use the same type with different settings |
| Amp type + variation | one of the MkII amp types | approximate; Gen 3 PUSHED has no direct MkII match |
| Power-amp variation, resonance | — | dropped |
| Chain orders 7–8 | chains 0–6 | approximate |
| Knob/pedal assigns | assign tables | mostly mappable; a few targets have no MkII counterpart |
| MkII-only fields | — | filled with MkII defaults |

`GREEN BASKET` as the example: only the Booster settings differ between colours (drive, bottom, effect level), so
only one colour's Booster survives; its MOD/FX, Delay and Reverb differ only in type and convert without loss.

A converter is planned as a separate project; see [the prior-art survey](2026-10-28-gen3-to-mkii-converters.md).
