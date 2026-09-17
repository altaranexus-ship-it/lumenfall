#!/usr/bin/env python3
"""LUMENFALL audio palette generator (AGE-23).

Deterministic procedural synthesis of the entire v1 audio palette:
  - ~40 SFX (beacon, player, footsteps, ambience, UI, hazard)
  - 2-layer adaptive music loop, phase-locked (LayerDark / LayerLit)
  - Rekindle reward sting = hero asset

Sonic identity (audio bible v1.0): warm analog synth + strings. "Dark" =
filtered detuned analog pads, sub drones, sparse noise. "Lit" = the same
palette opening up: brighter cutoffs, string-ensemble voicing, Karplus-Strong
plucked arpeggio. One synth family, two brightness states.

Every asset is reproducible from this script with fixed RNG seed 20260917.
Zero third-party samples -> zero licensing risk (MIT-clean).

Output: ../wav/<category>/<name>.wav  (44.1 kHz, 16-bit PCM, mono)
        ../gen/MANIFEST.json          (event catalog consumed by the bible)

Run:  python3 generate_palette.py
"""
import json
import math
import os
import struct
import wave

import numpy as np
from scipy.signal import lfilter

SR = 44100
SEED = 20260917
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "wav")

rng = np.random.default_rng(SEED)
MANIFEST = []


# ---------------------------------------------------------------- helpers --
def t(dur):
    return np.arange(int(round(dur * SR))) / SR


def note(midi):
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def onepole_lp(x, cutoff):
    a = math.exp(-2.0 * math.pi * cutoff / SR)
    return lfilter([1.0 - a], [1.0, -a], x)


def onepole_hp(x, cutoff):
    return x - onepole_lp(x, cutoff)


def sweep_lp(x, cutoff_series):
    """One-pole LP whose cutoff follows a per-sample (slowly varying) series."""
    y = np.empty_like(x)
    acc = 0.0
    block = 512
    for i in range(0, len(x), block):
        c = float(np.mean(cutoff_series[i:i + block]))
        a = math.exp(-2.0 * math.pi * c / SR)
        seg = lfilter([1.0 - a], [1.0, -a], x[i:i + block])
        seg[0] += acc * a  # continuity between blocks
        acc = seg[-1]
        y[i:i + block] = seg
    return y


def envexp(n, tau):
    return np.exp(-np.arange(n) / max(tau * SR, 1.0))


def adsr(n, a=0.01, d=0.05, s=0.7, r=0.05):
    a_n, d_n, r_n = (int(k * SR) for k in (a, d, r))
    s_n = max(n - a_n - d_n - r_n, 0)
    env = np.concatenate([
        np.linspace(0, 1, max(a_n, 1), endpoint=False),
        np.linspace(1, s, max(d_n, 1), endpoint=False),
        np.full(s_n, s),
        np.linspace(s, 0, max(r_n, 1)),
    ])
    if len(env) < n:
        env = np.pad(env, (0, n - len(env)))
    return env[:n]


def brownian(n, sigma=0.0006):
    c = np.cumsum(rng.normal(0.0, sigma, n))
    span = c.max() - c.min()
    return (c - c.min()) / (span + 1e-9) if span > 0 else np.full(n, 0.5)


def sat(x, drive=1.4):
    """Soft tanh saturation: the 'warm analog' glue."""
    return np.tanh(x * drive) / math.tanh(drive)


def chorus(x, rate=0.5, depth_s=0.005, mix=0.45):
    n = len(x)
    idx = np.arange(n)
    d = (depth_s * SR * (0.5 + 0.5 * np.sin(2 * math.pi * rate * idx / SR)))
    base = np.floor(d).astype(int)
    frac = d - base
    src = np.clip(idx - base, 0, n - 1)
    src2 = np.clip(src - 1, 0, n - 1)
    delayed = x[src] * (1 - frac) + x[src2] * frac
    return (1 - mix) * x + mix * delayed


def fade(x, ms_in=3.0, ms_out=10.0):
    ni = int(SR * ms_in / 1000)
    no = int(SR * ms_out / 1000)
    ni = min(ni, len(x) // 2)
    no = min(no, len(x) // 2)
    x = x.copy()
    x[:ni] *= np.linspace(0, 1, ni)
    x[-no:] *= np.linspace(1, 0, no)
    return x


def loopable(x, xf_ms=100.0):
    """Equal-power crossfade tail into head so the file loops seamlessly.
    NOTE: shortens the file by xf_ms (used only for non-quantised beds)."""
    nf = int(SR * xf_ms / 1000)
    body = x[:-nf].copy()
    tail = x[-nf:]
    w = np.linspace(0, math.pi / 2, nf)
    body[:nf] = body[:nf] * np.sin(w) + tail * np.cos(w)
    return body


def loop_fold(x, xf_ms, out_len):
    """Length-preserving seamless loop for bar-quantised music.

    Folds the xf_ms CONTINUATION (samples out_len..out_len+nf, i.e. the real
    decay tail bleeding past the loop point) into the head with an equal-power
    crossfade. x must contain out_len + nf samples; the result is EXACTLY
    out_len samples, so the loop keeps its declared 588000-frame length and
    the bar grid never drifts at the wrap (AGE-23 loop spec).
    """
    nf = int(SR * xf_ms / 1000)
    if x.shape[0] < out_len + nf:
        raise ValueError("loop_fold: need out_len + xf samples, got %d" % x.shape[0])
    out = x[:out_len].copy()
    tail = x[out_len:out_len + nf]
    w = np.linspace(0, math.pi / 2, nf)
    out[:nf] = out[:nf] * np.sin(w) + tail * np.cos(w)
    return out


def karplus(freq, dur, decay=0.996):
    """Karplus-Strong plucked string."""
    n_samples = int(round(dur * SR))
    period = max(int(SR / freq), 2)
    buf = rng.uniform(-1, 1, period)
    out = np.empty(n_samples)
    idx = 0
    for i in range(n_samples):
        nxt = (idx + 1) % period
        out[i] = buf[idx]
        buf[idx] = decay * 0.5 * (buf[idx] + buf[nxt])
        idx = nxt
    return out * envexp(n_samples, dur * 0.55)


def write(path, x, peak_db=-3.0, category="", event="", bus="SFX_World",
          kind="oneshot", loop_seconds=0.0, voice_limit=8, note=""):
    x = np.asarray(x, dtype=np.float64)
    peak = np.max(np.abs(x)) + 1e-12
    x = x / peak * (10.0 ** (peak_db / 20.0))
    pcm = np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
    full = os.path.join(OUT, category, os.path.basename(path))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with wave.open(full, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    MANIFEST.append({
        "event": event, "file": "res://audio/wav/%s/%s" % (category, os.path.basename(path)),
        "category": category, "bus": bus, "kind": kind,
        "seconds": round(len(x) / SR, 3), "loop_seconds": loop_seconds,
        "peak_db": peak_db, "voice_limit": voice_limit, "note": note,
    })
    print("  %-46s %5.2fs  %s" % (os.path.basename(path), len(x) / SR, category))


def noise(n):
    return rng.uniform(-1, 1, n)


# ------------------------------------------------------------ music voices --
def analog_pad(freqs, dur, bright_base=500.0, bright_top=2600.0, amp=1.0,
               attack=1.6, detunes=(-9.0, -3.5, 3.5, 9.0), sub=True):
    """Detuned saw stack + sub -> variable-cutoff LP + saturation + chorus.
    The cutoff follows a brownian drift path: the 'alive analog' feel."""
    n = int(round(dur * SR))
    tt = t(dur)
    out = np.zeros(n)
    for f in freqs:
        for cents in detunes:
            fr = f * 2.0 ** (cents / 1200.0)
            out += 0.055 * lfilter([0.6], [1.0, -0.4],  # tame saw edge
                                   np.sign(np.sin(2 * math.pi * fr * tt
                                          + rng.random() * 6.283)))
    if sub:
        out += 0.16 * np.sin(2 * math.pi * freqs[0] / 2 * tt)
    drift = onepole_lp(brownian(n, 0.0005), 1.5)
    cutoff = bright_base + (bright_top - bright_base) * drift
    out = sweep_lp(out, cutoff)
    out = sat(out, 1.6)
    out = chorus(out, rate=0.35, depth_s=0.006, mix=0.5)
    out *= adsr(n, a=attack, d=0.2, s=0.85, r=min(1.2, dur * 0.15))
    return out * amp


def string_ens(freqs, dur, amp=1.0, attack=0.9, vib_rate=5.2):
    """String-machine ensemble: detuned saws + vibrato + chorus -> band-ish LP.
    The 'strings' half of the identity; used by the lit layer."""
    n = int(round(dur * SR))
    tt = t(dur)
    vib = 1.0 + 0.006 * np.sin(2 * math.pi * vib_rate * tt
                               + rng.random() * 6.283)
    out = np.zeros(n)
    for f in freqs:
        for cents in (-7.0, 0.0, 7.0):
            fr = f * 2.0 ** (cents / 1200.0)
            out += 0.09 * (np.sign(np.sin(2 * math.pi * fr * tt * 1.0))
                           * 0.6 + 0.4 * np.sin(2 * math.pi * fr * tt))
    for k in range(0, n, 4096):
        seg = slice(k, min(k + 4096, n))
        out[seg] = out[seg] * vib[seg]
    out = onepole_lp(out, 2400.0)
    out = onepole_hp(out, 180.0)
    out = chorus(out, rate=0.55, depth_s=0.008, mix=0.55)
    out *= adsr(n, a=attack, d=0.3, s=0.8, r=min(1.0, dur * 0.12))
    return out * amp


BPM = 72.0
SPB = 60.0 / BPM                    # seconds per beat  = 0.833333
SAMPLES_PER_BAR = int(round(SPB * 4 * SR))   # = 147000, exact
LOOP_BARS = 4
LOOP_SAMPLES = SAMPLES_PER_BAR * LOOP_BARS   # = 588000 = 13.3333 s exactly
LOOP_SECONDS = LOOP_SAMPLES / SR
XF_N = int(round(SR * 0.120))  # 5292 — tail-fold window for the music layers


# ------------------------------------------------------------- the palette --
print("LUMENFALL palette generator — seed %d, SR %d" % (SEED, SR))
print("--- music: adaptive district loop (2 phase-locked layers) ---")


def music_dark_layer():
    """LayerDark: Am(add9) -> Fmaj7 -> Am -> G6. Filtered analog pad + sub
    pulse. Plays indefinitely without fatigue (bible rule)."""
    dur = (LOOP_SAMPLES + XF_N) / SR
    n = LOOP_SAMPLES + XF_N  # overshoot consumed by loop_fold
    out = np.zeros(n)

    # chord plan: (start_bar, freqs)
    A2, E3, C4, B3 = note(45), note(52), note(60), note(59)
    F2, C3, A3, E4 = note(41), note(48), note(57), note(64)
    G2, D3, B3b, E4b = note(43), note(50), note(58), note(64)
    chords = [
        (0, [A2, E3, B3, C4]),          # Am(add9)
        (1, [F2, C3, A3, E4]),          # Fmaj7
        (2, [A2, E3, B3, C4]),          # Am(add9)
        (3, [G2, D3, B3b, E4b]),        # G6(no3 flavor)
    ]
    for bar, freqs in chords:
        seg = analog_pad(freqs, SPB * 4 + 1.5, 380, 1900, amp=0.9, attack=1.8)
        s = bar * SAMPLES_PER_BAR
        e = min(s + len(seg), n)
        out[s:e] += seg[:e - s]

    # sub pulse: soft root heartbeat every 2 beats
    for beat in range(0, 16, 2):
        s = int(beat * SPB * SR)
        pulse = np.sin(2 * math.pi * 55 * t(0.9)) * envexp(int(0.9 * SR), 0.3)
        pulse = onepole_lp(pulse, 300)
        e = min(s + len(pulse), n)
        out[s:e] += pulse[:e - s] * 0.5

    out = loop_fold(out, 120, LOOP_SAMPLES)
    return out


def music_lit_layer():
    """LayerLit: I-V-vi-IV in A (A-E-F#m-D) warm major shift, string-ensemble
    pads + Karplus arpeggio on the 8th-note grid. Sample-exact tempo grid."""
    n = LOOP_SAMPLES + XF_N  # overshoot consumed by loop_fold
    out = np.zeros(n)

    A3, CSh4, E4, A4 = note(57), note(61), note(64), note(69)
    E3, B3, GSh4, E4b = note(52), note(59), note(68), note(64)
    FSh3, A3b, CSh4b, FSh4 = note(54), note(57), note(61), note(66)
    D3, FSh3b, A3c, D4 = note(50), note(54), note(57), note(62)
    chords = [
        (0, [A3, CSh4, E4], [45, 49, 52, 57]),   # A
        (1, [E3, B3, GSh4], [40, 44, 47, 52]),   # E
        (2, [FSh3, A3b, CSh4b], [42, 45, 49, 54]),  # F#m
        (3, [D3, FSh3b, A3c], [38, 42, 45, 50]),  # D
    ]
    for bar, pad_freqs, arp_midis in chords:
        seg = string_ens(pad_freqs, SPB * 4 + 1.2, amp=0.5, attack=1.1)
        seg += analog_pad([p / 2 for p in pad_freqs], SPB * 4 + 1.2,
                          500, 2400, amp=0.45, attack=1.4)
        s = bar * SAMPLES_PER_BAR
        e = min(s + len(seg), n)
        out[s:e] += seg[:e - s]
        # Karplus arpeggio: 8 eighth-notes per bar, up-down pattern
        for k in range(8):
            midi = arp_midis[k % len(arp_midis)] + (12 if k in (3, 7) else 0)
            pl = karplus(note(midi), 0.7, decay=0.9965) * 0.30
            s2 = s + int(round(k * SPB * 0.5 * SR))
            e2 = min(s2 + len(pl), n)
            out[s2:e2] += pl[:e2 - s2]

    out = loop_fold(out, 120, LOOP_SAMPLES)
    return out


dark = music_dark_layer()
write(os.path.join("district_loop_layerdark.wav"), dark, peak_db=-7.0, category="music",
      event="Music/District_Loop_LayerDark", bus="LayerDark", kind="loop",
      loop_seconds=LOOP_SECONDS, voice_limit=1,
      note="dark district layer; sample-exact 588000-sample loop")
lit = music_lit_layer()
write(os.path.join("district_loop_layerlit.wav"), lit, peak_db=-7.0, category="music",
      event="Music/District_Loop_LayerLit", bus="LayerLit", kind="loop",
      loop_seconds=LOOP_SECONDS, voice_limit=1,
      note="lit district layer; same length -> phase-locked with dark layer")

print("--- hero: rekindle reward sting ---")


def sting_rekindle():
    """HERO ASSET. Bloom: warm filtered-saw swell opening into a staggered
    plucked major(add9) chord + shimmer partials. Full by ~0.45 s, tail 2.8 s.
    Emotional payoff of the core loop — treat with care."""
    dur = 2.8
    n = int(round(dur * SR))
    tt = t(dur)
    out = np.zeros(n)

    # 1) warm riser: saw through opening LP, 0.05 -> bloom at 0.4 s
    rise_len = int(0.45 * SR)
    saw = np.zeros(rise_len)
    for f in (note(57), note(64), note(69)):
        for cents in (-6.0, 6.0):
            fr = f * 2 ** (cents / 1200)
            saw += 0.22 * np.sign(np.sin(2 * math.pi * fr * t(0.45)))
    cut = 200 + 4200 * (np.arange(rise_len) / rise_len) ** 2
    saw = sweep_lp(saw, cut) * adsr(rise_len, a=0.30, d=0.05, s=0.95, r=0.10)
    out[:rise_len] += sat(saw, 1.3) * 0.9

    # 2) staggered Karplus chord: A major add9 (A3 C#4 E4 B4 + A4)
    pluck_notes = [note(57), note(61), note(64), note(71), note(69)]
    offsets = [0.40, 0.435, 0.465, 0.50, 0.55]
    for f, off in zip(pluck_notes, offsets):
        pl = karplus(f, 1.9, decay=0.9975) * 0.42
        s = int(off * SR)
        out[s:s + len(pl)] += pl

    # 3) shimmer: beating high partials, slow decay (the 'light' halo)
    for f, amp, tau in ((note(81), 0.10, 1.0), (note(88), 0.05, 0.8),
                        (note(76) * 2, 0.035, 0.7)):
        out += amp * np.sin(2 * math.pi * f * tt + rng.random() * 6.28) \
            * envexp(n, tau)

    # 4) low warm bloom under everything (root A1/A2 swell)
    out += 0.20 * np.sin(2 * math.pi * note(45) * tt) * \
        adsr(n, a=0.35, d=0.4, s=0.35, r=1.4)

    out = sat(out * 0.9, 1.25)
    return fade(out, 2, 60)


write(os.path.join("sfx", "beacon", "rekindle_sting.wav"),
      sting_rekindle(), peak_db=-2.0, category="beacon",
      event="SFX/World/Beacon/Rekindle_Sting", bus="SFX_World",
      voice_limit=2, note="HERO reward sting; music ducks -6 dB under it")

print("--- beacon interaction SFX ---")


def kindle_hold():
    dur = 1.35
    n = int(round(dur * SR))
    tt = t(dur)
    ramp = (tt / dur) ** 1.4
    # crackle: sparse ticks accelerating with the hold
    ticks = (rng.random(n) < (0.004 + 0.05 * ramp)).astype(float)
    ticks *= rng.uniform(0.25, 1.0, n)
    ticks = onepole_lp(ticks, 3800) * 2.2
    # glow: low sine bed ramping up (the wick catching)
    glow = (np.sin(2 * math.pi * 55 * tt) + 0.4 * np.sin(2 * math.pi * 110 * tt))
    glow *= (0.05 + 0.45 * ramp)
    glow *= 1.0 + 0.15 * np.sin(2 * math.pi * 4.0 * tt)
    # airy rise into the hand-off
    air = onepole_hp(noise(n), 2500) * (0.02 + 0.16 * ramp)
    sweep = np.sin(2 * math.pi * (600 + 700 * ramp) * tt) * 0.05 * ramp
    out = ticks * 0.8 + glow * 0.55 + air + sweep
    # small pop at the end (hand-off moment to the sting)
    pop = np.sin(2 * math.pi * 180 * t(0.03)) * envexp(int(0.03 * SR), 0.01) * 0.5
    out[-len(pop):] += pop
    return out


def wick_loop():
    dur = 2.0
    n = int(round(dur * SR))
    tt = t(dur)
    steady = (rng.random(n) < 0.010).astype(float) * rng.uniform(0.2, 1.0, n)
    steady = onepole_lp(steady, 3600) * 1.6
    hiss = onepole_lp(noise(n), 2600) * 0.055
    bed = np.sin(2 * math.pi * 55 * tt) * (0.16 + 0.05 * np.sin(2 * math.pi * 0.7 * tt))
    bed += 0.35 * np.sin(2 * math.pi * 110 * tt)
    sput = (rng.random(n) < 0.0006).astype(float) * rng.uniform(0.5, 1.5, n)
    sput = onepole_lp(sput, 1200) * 3.0
    return loopable(steady + hiss + bed * 0.7 + sput, 90)


def kindle_fail():
    thump = np.sin(2 * math.pi * 70 * t(0.16)) * envexp(int(0.16 * SR), 0.05)
    thump *= (1.0 + 0.4 * np.linspace(0, -0.5, int(0.16 * SR)))
    puff = onepole_hp(noise(int(0.09 * SR)), 900) * envexp(int(0.09 * SR), 0.03) * 0.5
    hiss = onepole_lp(noise(int(0.45 * SR)), 3000) * envexp(int(0.45 * SR), 0.14) * 0.3
    # denied-major-2nd sizzle (tension refused)
    tt = t(0.5)
    fizz = (np.sin(2 * math.pi * 440 * tt) + np.sin(2 * math.pi * 466 * tt))
    fizz *= envexp(len(tt), 0.12) * 0.05
    out = np.zeros(int(0.55 * SR))
    out[:len(thump)] += thump * 0.8
    out[:len(puff)] += puff
    out[:len(hiss)] += hiss * 0.5
    out[:len(fizz)] += fizz
    return out


write(os.path.join("sfx", "beacon", "kindle_hold.wav"), kindle_hold(),
      peak_db=-6.0, category="beacon", event="SFX/World/Beacon/Kindle_Hold",
      bus="SFX_World", kind="oneshot", voice_limit=1,
      note="covers the full 1.2 s hold; restarted per attempt, pop = hand-off cue")
write(os.path.join("sfx", "beacon", "beacon_wick_loop.wav"), wick_loop(),
      peak_db=-12.0, category="beacon", event="SFX/World/Beacon/Wick_Loop",
      bus="SFX_World", kind="loop", loop_seconds=2.0, voice_limit=12)
write(os.path.join("sfx", "beacon", "kindle_fail.wav"), kindle_fail(),
      peak_db=-6.0, category="beacon", event="SFX/World/Beacon/Kindle_Fail",
      bus="SFX_World", voice_limit=2)

print("--- player movement ---")


def footstep(surface):
    """thump + filtered noise scuff; surface picks band + ring."""
    dur = rng.uniform(0.11, 0.16)
    n = int(round(dur * SR))
    thump = np.sin(2 * math.pi * rng.uniform(62, 95) * t(dur)) \
        * envexp(n, 0.035) * rng.uniform(0.5, 0.8)
    burst = noise(n) * envexp(n, rng.uniform(0.02, 0.035))
    if surface == "concrete":
        burst = onepole_lp(burst, rng.uniform(1400, 2200)) * 1.1
    else:  # stone: band + faint ring
        burst = onepole_hp(onepole_lp(burst, 1500), 350) * 1.3
        if rng.random() < 0.6:
            f = rng.uniform(1500, 2400)
            burst += 0.08 * np.sin(2 * math.pi * f * t(dur)) * envexp(n, 0.03)
    scuff = onepole_hp(noise(n), 4500) * envexp(n, 0.008) * 0.25
    return fade(thump * 0.8 + burst + scuff, 0.5, 8)


def jump_effort():
    dur = 0.22
    n = int(round(dur * SR))
    tt = t(dur)
    whoosh = sweep_lp(noise(n), 500 + 2300 * (tt / dur)) * envexp(n, 0.10)
    tick = np.sin(2 * math.pi * 120 * t(0.02)) * envexp(int(0.02 * SR), 0.008) * 0.4
    out = whoosh * 0.5
    out[:len(tick)] += tick
    return out


def land(hard):
    dur = 0.26 if hard else 0.18
    n = int(round(dur * SR))
    f0 = 55 if hard else 72
    thump = np.sin(2 * math.pi * f0 * t(dur)) * envexp(n, 0.07 if hard else 0.045)
    burst = onepole_lp(noise(n), rng.uniform(900, 1600)) * envexp(n, 0.05) * 0.9
    scuff = onepole_hp(noise(n), 4000) * envexp(n, 0.02) * 0.3
    return fade(thump * (1.0 if hard else 0.7) + burst + scuff, 0.5, 12)


def glide_loop():
    dur = 1.5
    n = int(round(dur * SR))
    tt = t(dur)
    wind = onepole_lp(noise(n), 750) * (0.55 + 0.2 * np.sin(2 * math.pi * 0.7 * tt))
    air = onepole_hp(noise(n), 2600) * 0.10
    return loopable(wind + air, 110)


def climb_grab():
    dur = 0.12
    n = int(round(dur * SR))
    scuff = onepole_hp(noise(n), 2200) * envexp(n, 0.025) * 0.8
    tap = np.sin(2 * math.pi * rng.uniform(300, 420) * t(dur)) * envexp(n, 0.015) * 0.4
    return fade(scuff + tap, 0.5, 6)


def climb_step():
    dur = 0.10
    n = int(round(dur * SR))
    burst = onepole_hp(onepole_lp(noise(n), 1200), 300) * envexp(n, 0.02)
    tap = np.sin(2 * math.pi * rng.uniform(180, 260) * t(dur)) * envexp(n, 0.012) * 0.5
    return fade(burst + tap, 0.5, 5)


def lumen_gain():
    dur = 0.6
    out = np.zeros(int(round(dur * SR)))
    swell = onepole_hp(noise(int(0.22 * SR)), 1800) \
        * np.linspace(0, 1, int(0.22 * SR)) ** 2 * 0.25
    out[:len(swell)] += swell
    pl = karplus(note(81), 0.45, decay=0.996) * 0.35
    s = int(0.20 * SR)
    e = min(s + len(pl), len(out))
    out[s:e] += pl[:e - s]
    return out


for i in range(8):
    write(os.path.join("sfx", "player", "footstep_concrete_%02d.wav" % (i + 1)),
          footstep("concrete"), peak_db=-8.0, category="player",
          event="SFX/Player/Footstep_Concrete_%02d" % (i + 1), bus="SFX_Player",
          voice_limit=6)
for i in range(6):
    write(os.path.join("sfx", "player", "footstep_stone_%02d.wav" % (i + 1)),
          footstep("stone"), peak_db=-8.0, category="player",
          event="SFX/Player/Footstep_Stone_%02d" % (i + 1), bus="SFX_Player",
          voice_limit=6)
for i in range(2):
    write(os.path.join("sfx", "player", "jump_%02d.wav" % (i + 1)),
          jump_effort(), peak_db=-10.0, category="player",
          event="SFX/Player/Jump_%02d" % (i + 1), bus="SFX_Player", voice_limit=3)
for i in range(4):
    write(os.path.join("sfx", "player", "land_%s_%02d.wav"
                       % ("hard" if i < 2 else "soft", (i % 2) + 1)),
          land(i < 2), peak_db=(-6.0 if i < 2 else -9.0), category="player",
          event="SFX/Player/Land_%s_%02d" % ("Hard" if i < 2 else "Soft",
                                             (i % 2) + 1),
          bus="SFX_Player", voice_limit=3)
write(os.path.join("sfx", "player", "glide_loop.wav"), glide_loop(),
      peak_db=-12.0, category="player", event="SFX/Player/Glide_Loop",
      bus="SFX_Player", kind="loop", loop_seconds=1.5, voice_limit=1)
for i in range(2):
    write(os.path.join("sfx", "player", "climb_grab_%02d.wav" % (i + 1)),
          climb_grab(), peak_db=-10.0, category="player",
          event="SFX/Player/Climb_Grab_%02d" % (i + 1), bus="SFX_Player",
          voice_limit=3)
for i in range(3):
    write(os.path.join("sfx", "player", "climb_step_%02d.wav" % (i + 1)),
          climb_step(), peak_db=-11.0, category="player",
          event="SFX/Player/Climb_Step_%02d" % (i + 1), bus="SFX_Player",
          voice_limit=3)
write(os.path.join("sfx", "player", "lumen_gain.wav"), lumen_gain(),
      peak_db=-9.0, category="player", event="SFX/Player/Lumen_Gain",
      bus="SFX_Player", voice_limit=2)

print("--- ambience: district states ---")


def amb_dark():
    dur = 6.0
    n = int(round(dur * SR))
    tt = t(dur)
    lfo = 0.55 + 0.3 * np.sin(2 * math.pi * 0.13 * tt + 0.4) \
        * np.sin(2 * math.pi * 0.047 * tt)
    wind = onepole_lp(noise(n), 420) * lfo
    wind += onepole_hp(onepole_lp(noise(n), 900), 250) * lfo * 0.25
    drone = np.sin(2 * math.pi * 55 * tt) + np.sin(2 * math.pi * 55.5 * tt)
    out = wind * 0.5 + drone * 0.045
    # sparse distant resonant creaks (deterministic placements)
    for pos, f in ((1.7, 820.0), (4.4, 640.0)):
        creak = onepole_lp(noise(int(0.5 * SR)), f) \
            * envexp(int(0.5 * SR), 0.16) * 0.10
        s = int(pos * SR)
        out[s:s + len(creak)] += creak
    return loopable(out, 250)


def amb_lit():
    dur = 6.0
    n = int(round(dur * SR))
    tt = t(dur)
    bed = onepole_lp(noise(n), 4000) * 0.035          # ember hiss
    warm = onepole_lp(noise(n), 300) * (0.10 + 0.03 * np.sin(2 * math.pi * 0.09 * tt))
    out = bed + warm
    for pos, f, amp in ((2.1, note(84), 0.05), (4.6, note(88), 0.035)):
        chime = np.sin(2 * math.pi * f * t(1.2)) * envexp(int(1.2 * SR), 0.5) * amp
        chime += 0.4 * np.sin(2 * math.pi * f * 1.5 * t(1.2)) \
            * envexp(int(1.2 * SR), 0.3) * amp
        s = int(pos * SR)
        out[s:s + len(chime)] += chime
    return loopable(out, 250)


write(os.path.join("ambience", "district_dark_loop.wav"), amb_dark(),
      peak_db=-12.0, category="ambience", event="Ambience/District_Dark_Loop",
      bus="Ambience", kind="loop", loop_seconds=6.0, voice_limit=1,
      note="dark state; LP-filtered on the Ambience bus")
write(os.path.join("ambience", "district_lit_loop.wav"), amb_lit(),
      peak_db=-12.0, category="ambience", event="Ambience/District_Lit_Loop",
      bus="Ambience", kind="loop", loop_seconds=6.0, voice_limit=1,
      note="lit state; crossfade 3 s against dark loop")

print("--- UI ---")


def ui_tone(seq, dur=0.07):
    n = int(round(dur * SR))
    out = np.zeros(n)
    step = n // len(seq)
    for i, f in enumerate(seq):
        seg = np.sin(2 * math.pi * f * t(step / SR)) \
            * adsr(step, 0.002, 0.01, 0.6, 0.02)
        s = i * step
        e = min(s + len(seg), n)
        out[s:e] += seg[:e - s]
    return fade(out * 0.7, 0.5, 8)


write(os.path.join("ui", "hover.wav"), ui_tone([1050]), peak_db=-12.0,
      category="ui", event="UI/Hover", bus="UI", voice_limit=4)
write(os.path.join("ui", "select.wav"), ui_tone([880, 1320]), peak_db=-10.0,
      category="ui", event="UI/Select", bus="UI", voice_limit=4)
write(os.path.join("ui", "back.wav"), ui_tone([660, 440]), peak_db=-10.0,
      category="ui", event="UI/Back", bus="UI", voice_limit=4)


def save_chime():
    out = np.zeros(int(0.8 * SR))
    for f, off, amp in ((note(72), 0.0, 0.30), (note(76), 0.09, 0.25)):
        pl = karplus(f, 0.6, decay=0.9965) * amp
        s = int(off * SR)
        e = min(s + len(pl), len(out))
        out[s:e] += pl[:e - s]
    return out


write(os.path.join("ui", "save_chime.wav"), save_chime(), peak_db=-12.0,
      category="ui", event="UI/Save_Chime", bus="UI", voice_limit=2)


def checkpoint_bell():
    dur = 1.3
    n = int(round(dur * SR))
    tt = t(dur)
    out = np.zeros(n)
    for f, amp, tau in ((660.0, 0.30, 0.6), (990.0, 0.12, 0.4),
                        (1320.0, 0.07, 0.3), (659.3, 0.10, 0.9)):
        out += amp * np.sin(2 * math.pi * f * tt + rng.random() * 6.28) \
            * envexp(n, tau)
    return fade(out, 1, 80)


write(os.path.join("ui", "checkpoint_bell.wav"), checkpoint_bell(),
      peak_db=-8.0, category="ui", event="UI/Checkpoint_Bell", bus="UI",
      voice_limit=2)

print("--- hazard ---")


def hazard_hit():
    dur = 0.45
    n = int(round(dur * SR))
    tt = t(dur)
    clang = np.zeros(n)
    for f, amp, tau in ((220.0, 0.4, 0.18), (587.0, 0.2, 0.10),
                        (932.0, 0.12, 0.07), (1400.0, 0.06, 0.05)):
        clang += amp * np.sign(np.sin(2 * math.pi * f * tt)) * envexp(n, tau)
    clang = onepole_lp(clang, 3600)
    burst = onepole_lp(noise(n), 2400) * envexp(n, 0.03) * 0.7
    thud = np.sin(2 * math.pi * 70 * tt) * envexp(n, 0.08) * 0.6
    return fade(sat(clang + burst + thud, 1.5), 0.5, 20)


def fail_reset():
    dur = 0.8
    n = int(round(dur * SR))
    tt = t(dur)
    f = 420.0 * 2 ** (-2.2 * tt / dur)
    ph = 2 * math.pi * np.cumsum(f) / SR
    sweep = np.sign(np.sin(ph)) * adsr(n, 0.01, 0.2, 0.6, 0.15)
    sweep = sweep_lp(sweep, 900 + 400 * tt)
    thud = np.sin(2 * math.pi * 55 * tt) * envexp(n, 0.25) * 0.5
    return fade(sat(sweep * 0.5 + thud, 1.4), 2, 40)


write(os.path.join("sfx", "world", "hazard_hit.wav"), hazard_hit(),
      peak_db=-6.0, category="world", event="SFX/World/Hazard_Hit",
      bus="SFX_World", voice_limit=4)
write(os.path.join("sfx", "world", "fail_reset.wav"), fail_reset(),
      peak_db=-8.0, category="world", event="SFX/World/Fail_Reset",
      bus="SFX_World", voice_limit=2)

# ----------------------------------------------------------------- summary --
os.makedirs(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gen"),
            exist_ok=True)
mpath = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "..", "gen", "MANIFEST.json"))
with open(mpath, "w") as f:
    json.dump({"seed": SEED, "sr": SR, "bpm": BPM, "loop_bars": LOOP_BARS,
               "loop_samples": LOOP_SAMPLES, "events": MANIFEST}, f, indent=2)
print("---\n%d events written -> %s" % (len(MANIFEST), mpath))
