# Other editors and ports for the KATANA MkII

Surveyed 2026-10-28 (GitHub, SourceForge). Alternatives to Roland's editor, and related libraries.

| Project | Platform | Licence | What it is | Last activity |
|---|---|---|---|---|
| [pwhofman/tanto](https://github.com/pwhofman/tanto) (Tantō) | macOS 15+, Apple Silicon, Swift | MIT | An independent editor and librarian with its own UI; tested only with the KATANA-100 MkII and refuses other models for now; unsigned, so macOS asks to allow it | 2026-10 |
| [luismaglz/katana50-mkII-linux](https://github.com/luismaglz/katana50-mkII-linux) (Kataka) | Linux, C#/Avalonia | GPL-3.0 | An independent editor for the KATANA-50 MkII: channels, effect chain, live knob feedback, `.tsl` load/save; work in progress | 2026-07 |
| [Katana MK2 FxFloorBoard](https://sourceforge.net/projects/fxfloorboard/files/KatanaFxFloorBoard/Katana%20FxFloorboard%20for%20MK2%20Desktop/) (gumtown) | Windows, macOS, Linux, Qt | GPL | Long-running independent editor for the MkII range (also packaged as a [Nix flake](https://github.com/kczulko/Katana-MK2-FxFloorBoard-nix-flake)) | 2026-01 (binaries) |
| [LeonLav77/music-master](https://github.com/LeonLav77/music-master) | Python | none stated | A Python library and HTTP/WebSocket API controlling a KATANA MkII head over USB MIDI, with `.tsl` loading | 2026-09 |
| [katana-dev/lib-katana](https://github.com/katana-dev/lib-katana) | Go/C | GPL-3.0 | SysEx and `.tsl` library from the original KATANA era | 2017 |
| [Powerlated/BOSS-TONE-STUDIO-for-Linux](https://github.com/Powerlated/BOSS-TONE-STUDIO-for-Linux) | Linux, Tauri | none stated | Runs Roland's **Gen 3** editor web app on Linux, downloading Roland's installer at build time (the original of the [Linux port](2026-10-28-linux-port.md)) | 2025-06 |

## How this project differs

The independent editors reimplement the amp's controls with their own UI and parameter tables. This project keeps
Roland's own editor — its UI, Librarian, Tone Central and every parameter — and only replaces the Intel-only shell, so
it covers the whole MkII range the editor supports and existing Librarians carry over.

Useful facts confirmed by these projects: without BOSS's KATANA Driver for macOS the amp does not appear as a MIDI
device (Tantō's README); `.tsl` files are shared between Roland's editor and the independent ones.
