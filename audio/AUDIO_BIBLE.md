# LUMENFALL — Audio Design Bible v1.0 (AGE-23)

Companion to the GDD one-pager (AGE-18 `gdd-one-pager`) and the AGE-16 Vertical
Slice Plan deliverable #7. Engine target: Godot 4.5+ (verified on 4.7.2).
Everything in this bible is implemented in-repo: `scripts/core/audio_manager.gd`
(runtime), `default_bus_layout.tres` (buses), `audio/wav/**` (assets),
`audio/gen/generate_palette.py` (procedural source of truth),
`audio/gen/MANIFEST.json` (asset catalog), `tests/smoke_audio.gd` (headless QA).

## 1. Sonic identity — "warm analog synth + strings"

One synth family, two brightness states. Nothing in LUMENFALL's soundscape is
bright plastic or digital-harsh; every voice passes through the same warm glue
(tanh soft saturation + chorus) so the whole mix reads as one instrument played
in one room.

- **Dark (unlit district):** detuned analog saw pads through a closed low-pass,
  55 Hz sub heartbeat, sparse wind/creak noise. Minor-leaning harmony:
  Am(add9) → Fmaj7 → Am → G6. The world sounds like held breath.
- **Lit (rekindled district):** the same pads with the filter opened + a string
  ensemble ("string machine": detuned saws, vibrato, chorus) and Karplus-Strong
  plucked arpeggios. Warm major shift: A → E → F#m → D. The world exhales.
- **The rekindle sting** is the hinge between the two states — it *is* the
  sonic identity in one gesture (see §4).

Tone anchor from the GDD: Ghibli-adjacent melancholy-hopeful. Quiet, warm
agency. No combat, no stingers-of-violence; tension cues resolve into warmth.

## 2. Palette rules (hard rules for any future asset drop)

1. **Zero third-party samples.** Every asset is procedurally synthesized by
   `audio/gen/generate_palette.py`, seed `20260917`, 44.1 kHz 16-bit PCM mono.
   MIT-clean by construction; byte-reproducible.
2. **No event ships with engine defaults.** Every event has a peak-normalized
   level (−2 to −12 dBFS, see MANIFEST), a bus assignment, and a voice limit.
   Nothing relies on 0 dB unit gain or unlimited polyphony.
3. **Named-event table only.** Gameplay code never references asset paths;
   it fires named events consumed by `AudioManager` (event → path table).
   Swapping a WAV never requires touching gameplay scripts.
4. **Music never fatigues.** The loop is 4 bars @ 72 BPM with no lead melody
   hook; interest comes from filter drift (brownian cutoff movement) and the
   adaptive layering, not from dense writing.
5. **Honest DSP, quantised where it matters.** Music layers are sample-exact
   (588,000 frames/bar grid, 147,000 frames per bar) so the two layers stay
   phase-locked forever from a same-frame start.

## 3. Adaptive music loop spec — "district loop"

| Parameter | Value |
|---|---|
| Tempo | 72 BPM (0.833333 s/beat, 147000 samples/bar @ 44.1 kHz) |
| Form | 4 bars, looped (13.3333 s), seamless via tail-fold crossfade |
| Layer A (LayerDark bus) | Am(add9) Fmaj7 Am G6 — filtered analog pad + sub pulse every 2 beats |
| Layer B (LayerLit bus) | A E F#m D — string ensemble + analog pad sub-octave + Karplus 8th-note arpeggio |
| Phase lock | both layers start the same frame; identical length → never drift |
| Loop construction | 120 ms continuation tail folded into the head (equal-power), length preserved exactly |

**Adaptive parameter — `district_lit_ratio` = kindled_rekindle_nodes / total_rekindle_nodes.**
This is the same ratio the F9 debug overlay shows as `nodes k/n`, so audio and
QA read the identical state. Drives, with 3 s linear smoothing:

- `LayerLit` bus volume: `linear_to_db(ratio)` (silent at 0, full at 1).
- `LayerDark` bus low-pass cutoff: 800 Hz (dark) → 9000 Hz (lit).
- Ambience crossfade: dark bed ↔ lit bed mirrors the same ratio.

An audio director can override polling via `AudioManager.set_lit_ratio(x)`;
the override disables group polling until restart. Bar-quantised layer switches
are deliberately NOT used in v1 — both layers always play, only gain/filter
move, which keeps transitions gapless and sample-locked.

## 4. Hero asset — the rekindle reward sting (2.8 s)

The emotional payoff of the core loop; everything else supports this moment.

1. **0.00–0.45 s Bloom-in:** detuned saw swell (A3/E4/A4) through a rapidly
   opening low-pass (200 → 4200 Hz), saturated — the "gasping into light".
2. **0.40–0.55 s Pluck bloom:** staggered Karplus-Strong chord, A major add9
   (A3, C#4, E4, B4, A4) entering at 35 ms intervals — light cascading.
3. **0–2.8 s Shimmer halo:** slow-decaying high partials (A5, E6) with slow
   beating — the afterglow.
4. **Throughout:** A2 root swell underneath anchors it to the world's key.

**Mix rule: when the sting fires, music ducks −6 dB** (8 ms attack, 0.6 s hold,
2.2 s release) so the sting owns the transients. Implemented in
`AudioManager._duck_music()`.

## 5. Godot audio bus hook spec

`default_bus_layout.tres` — 9 buses, ships with the project (no runtime setup):

```
Master                limiter: threshold -1 dB, ceiling -0.3 dB (safety)
├─ Music              (bus routing only)
│  ├─ LayerDark       LowPassFilter "DarkSheen" 2600 Hz base; AudioManager
│  │                  drives cutoff 800→9000 Hz with lit_ratio
│  └─ LayerLit        (gain driven by lit_ratio; starts at -60 dB)
├─ Ambience           LowPassFilter "AmbienceDarkCloak" 900 Hz — dark beds
│                     are muffled by topology, not just mix
├─ SFX
│  ├─ SFX_Player      3D positional movement voices
│  └─ SFX_World       Reverb "RuinsRoom" (room 0.45, wet 0.12) — beacon/world
└─ UI                 non-positional, always dry
```

Hook points (all wired in `scripts/core/audio_manager.gd`, tree-observed via
groups/signals — **zero edits to AGE-21 gameplay scripts**):

| Game signal | Audio response |
|---|---|
| `rekindle.kindled` | HERO sting (positional at the node) + music duck −6 dB |
| `rekindle.state_changed` → CARRYING | `Kindle_Hold` cue at the node (per-attempt) |
| hold released before completion | cue stops + `Kindle_Fail` (denied-major-2nd sizzle) |
| `light_carrier.lumen_changed` (grant) | `Lumen_Gain` |
| `checkpoint.checkpoint_saved` | `Checkpoint_Bell` on UI bus |
| `player.state_changed` | jump / land(hard\|soft) / climb-grab cues |
| glide toggle | `Glide_Loop` start/stop |
| footsteps (scheduler) | stride-scaled random variants (concrete pool v1; stone reserved) |
| district lit ratio | LayerLit gain + LayerDark filter + ambience crossfade (§3) |

Performance budget (per AGE-16): v1 mix sits at ≤ 20 concurrent voices
(global cap, steal-oldest), typically 8–12. Per-event voice limits in
`AudioManager.VOICE_LIMITS`. Web export cost is negligible — all assets are
pre-rendered 16-bit mono PCM; DSP is three filters + one reverb + one limiter.

## 6. SFX palette (~40 events, full catalog in `audio/gen/MANIFEST.json`)

| Family | Events | Notes |
|---|---|---|
| Music | 2 | district loop LayerDark / LayerLit (§3) |
| Beacon | 4 | Rekindle_Sting (HERO), Kindle_Hold, Kindle_Fail, Wick_Loop |
| Player | 27 | 8 concrete + 6 stone footsteps, 2 jump, 2 land hard, 2 land soft, glide loop, 2 climb grab, 3 climb step, lumen gain |
| Ambience | 2 | district dark / lit beds (6 s crossfaded loops) |
| UI | 5 | hover, select, back, save chime, checkpoint bell |
| World | 2 | hazard hit, fail reset |

Total: **42 events**, every one with declared bus, peak level, kind
(oneshot/loop), and voice limit.

## 7. Verification (reproducible)

```sh
# regenerate entire palette byte-for-byte (seed 20260917)
python3 audio/gen/generate_palette.py

# headless audio smoke: boots the real greybox map, checks buses, event
# table integrity (>= 40 events), adaptive ratio convergence, sting+duck
# path, and the 20-voice global cap under a 30x hammer
godot --headless --path . res://tests/smoke_audio.tscn
# exit 0 + AUDIO_SMOKE_RESULT=PASS = green
```

## 8. v1.1 reserves (out of scope for this issue)

- Stone-surface footstep routing (assets shipped, scheduler hook reserved).
- Dim-back (KINDLED → DORMANT) transition cue — v2 mechanic.
- Bark/VO line mixing (AGE-24 owns the script; routes through UI/SFX_World).
- District-specific music variation — only if the map grows past 3 zones.
