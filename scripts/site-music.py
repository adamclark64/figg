"""Synthesize the landing page music (site/music.mp3): an original piece of
80s waiting-room funk, slowed down like a vaporwave tape. Needs numpy, and
lame on PATH:

    python3 scripts/site-music.py /tmp/music.wav
    lame -V 6 -q 2 /tmp/music.wav site/music.mp3

The tune is deliberately small: a popping FM synth bass, a glassy DX electric
piano on maj9 chords, a steel drum that carries the melody, and a drum kit of
kick, hats, a conga tap and synth toms (no snare or clap on purpose). The
jokes are kept quiet: an elevator ding where the loop comes round, a tuned
cowbell in the middle eight, a steel drum note that melts at the end.

Form, 32 bars at 112 BPM: A (groove, two small fills), A (melody), B (the
hook, in steel band thirds), A' (melody, home through a minor iv). It is
written in C and moved up by TR semitones, then slowed by 3/4 so pitch and
tempo drop together (a fourth down, 84 BPM), with reverb, a little tape wow
and a gentle saturation. Pass a second argument to hear some stems alone:

    python3 scripts/site-music.py /tmp/steel.wav steel,bass

Everything is rendered on a circular timeline so the loop is seamless: reverb
tails and note releases wrap from the end back onto the start, and the
slow-down is a periodic FFT resample. The output WAV is the loop with a little
of its own tail before and head after (PAD seconds), so the page can loop
between loopStart/loopEnd without caring about mp3 encoder padding. The loop
is 4032000 frames at 44.1 kHz; the page hardcodes that length.
"""
import sys
import wave
import numpy as np

SR = 44100
BPM = 112
BEAT = 60 / BPM
BARS = 32
N = int(round(BARS * 4 * BEAT * SR))  # 3024000
SLOW = (3, 4)  # output length = N * 4 / 3
PAD = 0.5
TR = 2         # written in C, played in D, heard (slowed) in A
SWING = 0.03   # beats added to every off-beat sixteenth
DRIVE = 1.4    # tape saturation; 3 and up is the old blown-speaker sound
rng = np.random.default_rng(11)

STEMS = {}
SEND = np.zeros((2, N))
SOLO = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None


def hz(m):
    return 440.0 * 2 ** ((m + TR - 69) / 12)


def at(beats):
    """Sample position of a beat, with the off-beat sixteenths swung."""
    q = beats * 4
    if abs(q - round(q)) < 1e-9 and int(round(q)) % 2 == 1:
        beats += SWING
    return int(round(beats * BEAT * SR)) % N


def place(sig, start, gain_l, gain_r, send=0.0, bus="keys"):
    """Add sig to a stem at sample `start`, wrapping around the loop."""
    if SOLO and bus not in SOLO:
        return
    buf = STEMS.setdefault(bus, np.zeros((2, N)))
    start %= N
    n = len(sig)
    head = min(n, N - start)
    for ch, g in ((0, gain_l), (1, gain_r)):
        buf[ch, start:start + head] += sig[:head] * g
        buf[ch, :n - head] += sig[head:] * g
        if send:
            SEND[ch, start:start + head] += sig[:head] * g * send
            SEND[ch, :n - head] += sig[head:] * g * send


def saw(f, tt, bright, harmonics=24):
    """Band-limited saw; `bright` may be an array (a filter envelope)."""
    out = np.zeros_like(tt)
    for k in range(1, harmonics + 1):
        if f * k > 12000:
            break
        out += np.sin(2 * np.pi * f * k * tt) / k * np.exp(-k / bright)
    return out


# --- harmony ------------------------------------------------------------------
# name: (bass note, keyboard voicing, scale the melody harmonizes in)
MAJ = {0, 2, 4, 5, 7, 9, 11}
CH = {
    "Fmaj9": (41, [64, 67, 69, 72], MAJ),
    "Em7":   (40, [62, 67, 71, 74], MAJ),
    "Dm9":   (38, [60, 64, 65, 69], MAJ),
    "Cmaj9": (36, [59, 62, 64, 67], MAJ),
    "A9":    (45, [61, 64, 67, 71], {1, 2, 4, 5, 7, 9, 11}),
    "G9sus": (43, [60, 62, 65, 69], MAJ),
    "Am9":   (45, [60, 64, 67, 71], MAJ),
    "D9":    (38, [60, 64, 66, 69], {0, 2, 4, 6, 7, 9, 11}),
    "Fm6":   (41, [60, 62, 65, 68], {0, 2, 4, 5, 7, 8, 10}),
    "Gm7":   (43, [58, 62, 65, 70], {0, 2, 4, 5, 7, 9, 10}),
    "C9":    (36, [58, 62, 64, 67], {0, 2, 4, 5, 7, 9, 10}),
}


def bars(*names):
    """One entry per bar; 'X/Y' splits a bar in half."""
    return [[(4 / len(b.split("/")), c) for c in b.split("/")] for b in names]


A = bars("Fmaj9", "Em7", "Dm9", "Cmaj9", "Fmaj9", "Em7/A9", "Dm9", "G9sus")
B = bars("Am9", "D9", "Fmaj9", "G9sus", "Am9", "D9", "Dm9/G9sus", "Cmaj9/C9")
A_HOME = A[:4] + bars("Dm9", "Fm6", "Cmaj9", "Gm7/C9")
FORM = A + A + B + A_HOME
SEC_A1, SEC_A2, SEC_B, SEC_A3 = 0, 8, 16, 24  # first bar of each section

# Flat list of (start beat, length in beats, chord name).
CHORDS = []
for bar, row in enumerate(FORM):
    off = 0.0
    for ln, name in row:
        CHORDS.append((bar * 4 + off, ln, name))
        off += ln


def chord_at(beat):
    beat %= BARS * 4
    for start, ln, name in CHORDS:
        if start <= beat < start + ln:
            return CH[name]
    return CH[CHORDS[-1][2]]


# --- electric piano and pad ---------------------------------------------------
def epiano(m, ln_s, vel, cents):
    """DX-style electric piano: a soft FM body plus a short glassy tine."""
    n = int((ln_s + 0.5) * SR)
    tt = np.arange(n) / SR
    ph = 2 * np.pi * hz(m) * 2 ** (cents / 1200) * tt
    body = np.sin(ph + (0.8 * vel * np.exp(-tt / 0.5) + 0.1) * np.sin(ph)) * np.exp(-tt / 1.8)
    tine = np.sin(ph + 0.9 * np.exp(-tt / 0.06) * np.sin(14 * ph)) * np.exp(-tt / 0.35) * 0.25 * vel
    env = 1 - np.exp(-tt / 0.003)
    rel = tt > ln_s
    env[rel] *= np.exp(-(tt[rel] - ln_s) / 0.12)
    return (body + tine) * env * vel


for start, ln, name in CHORDS:
    root, notes, _ = CH[name]
    # Comping: the chord, a ghosted push, then the chord again off the beat.
    hits = [(0, 1.4, 1.0), (1.75, 0.3, 0.45), (2.5, 1.3, 0.8)] if ln == 4 else [(0, 1.6, 1.0)]
    for hb, hl, vel in hits:
        for m in notes:
            for cents, pan in ((-4, 0.3), (4, 0.7)):
                v = epiano(m, hl * BEAT, vel, cents) * 0.032
                place(v, at(start + hb), 1 - pan, pan, send=0.35, bus="keys")

    # Pad: only from the hook onwards, low in the mix, so the second half opens up.
    if start >= SEC_B * 4:
        n = int((ln * BEAT + 0.9) * SR)
        tt = np.arange(n) / SR
        env = (1 - np.exp(-tt / 0.25))
        rel = tt > ln * BEAT
        env[rel] *= np.exp(-(tt[rel] - ln * BEAT) / 0.35)
        for m in notes[1:]:
            for cents, pan in ((-7, 0.2), (7, 0.8)):
                v = saw(hz(m) * 2 ** (cents / 1200), tt, 3.0) * env * 0.015
                place(v, at(start), 1 - pan, pan, send=0.6, bus="pad")


# --- bass: FM synth bass with octave pops ---------------------------------------
def bass(m, ln_s, kind="n", slide=False):
    """kind: n (note), g (ghost), p (octave pop)."""
    n = int((ln_s + 0.08) * SR)
    tt = np.arange(n) / SR
    pitch = 2 ** (-2 * np.exp(-tt / 0.035) / 12) if slide else np.ones(n)
    ph = 2 * np.pi * hz(m) * np.cumsum(pitch) / SR
    if kind == "p":
        idx, env, gain = 5.5 * np.exp(-tt / 0.035) + 0.8, np.exp(-tt / 0.12), 0.75
    elif kind == "g":
        idx, env, gain = 2.5 * np.exp(-tt / 0.02) + 0.3, np.exp(-tt / 0.05), 0.5
    else:
        idx, env, gain = 3.2 * np.exp(-tt / 0.07) + 0.7, 0.75 + 0.25 * np.exp(-tt / 0.15), 1.0
    x = np.sin(ph + idx * np.sin(ph)) + (0.5 * np.sin(ph) if kind == "n" else 0)
    env = env * (1 - np.exp(-tt / 0.003))
    rel = tt > ln_s
    env[rel] *= np.exp(-(tt[rel] - ln_s) / 0.015)
    return x * env * gain


def approach(next_root, chromatic):
    """The note that leads into the next bar's root."""
    if chromatic:
        return next_root - 1
    return next_root - 5 if next_root - 5 >= 35 else next_root + 7


for bar, row in enumerate(FORM):
    b0 = bar * 4
    nxt = CH[FORM[(bar + 1) % BARS][0][1]][0]
    lead_in = (3.5, approach(nxt, bar % 4 == 3), 0.4, "n")
    if len(row) == 2:
        r1, r2 = CH[row[0][1]][0], CH[row[1][1]][0]
        line = [(0, r1, 0.6, "n"), (0.75, r1, 0.15, "g"), (1.5, r1 + 12, 0.2, "p"),
                (2, r2, 0.6, "n"), (2.75, r2, 0.15, "g"), lead_in]
    else:
        r = CH[row[0][1]][0]
        if bar % 2 == 0:
            line = [(0, r, 0.6, "n"), (0.75, r, 0.15, "g"), (1.5, r + 12, 0.2, "p"),
                    (2.5, r, 0.4, "n"), lead_in]
        else:
            line = [(0, r, 0.6, "n"), (1.5, r + 7, 0.3, "n"), (1.75, r + 12, 0.2, "p"),
                    (2.5, r, 0.4, "n"), (3.0, r + 12, 0.18, "p"), lead_in]
    for beat, m, ln, kind in line:
        v = bass(m, ln * BEAT, kind, slide=(bar % 4 == 0 and beat == 0)) * 0.21
        place(v, at(b0 + beat), 0.5, 0.5, send=0.03, bus="bass")


# --- steel drum -----------------------------------------------------------------
def steel(m, vel=1.0, droop=0.0):
    """A steel pan: strong octave partial, a clang on the strike, a long ring.
    `droop` (semitones) lets the note sag as it rings, like a warped tape."""
    f = hz(m) * 2 ** (rng.uniform(-6, 6) / 1200)
    n = int(1.7 * SR)
    tt = np.arange(n) / SR
    pitch = 1 + 0.006 * np.exp(-tt / 0.025)
    if droop:
        pitch = pitch * 2 ** (-droop * np.clip((tt - 0.12) / 0.9, 0, 1) ** 1.5 / 12)
    ph = 2 * np.pi * f * np.cumsum(pitch) / SR
    tau = 0.5 * (hz(72) / f) ** 0.5
    idx = 1.6 * np.exp(-tt / 0.05) + 0.2
    x = np.sin(ph + idx * np.sin(ph)) * np.exp(-tt / tau)
    x += 0.7 * np.sin(2.004 * ph + 0.5 * idx * np.sin(ph)) * (1 - np.exp(-tt / 0.015)) * np.exp(-tt / (tau * 0.7))
    x += 0.3 * np.sin(4.01 * ph) * np.exp(-tt / (tau * 0.3))
    x += 0.12 * np.sin(5.37 * ph) * np.exp(-tt / 0.03)
    return x * (1 - np.exp(-tt / 0.002)) * vel


def below(m, scale, steps):
    """The note `steps` scale steps under m."""
    while steps:
        m -= 1
        if m % 12 in scale:
            steps -= 1
    return m


def strike(m, beat, vel, pan, droop=0.0, shift=0.0):
    """One hit, `shift` beats after `beat` (rolls and echoes ignore the swing)."""
    v = steel(m, vel, droop) * 0.085
    pos = at(beat) + int(round(shift * BEAT * SR))
    place(v, pos, 1 - pan, pan, send=0.5, bus="steel")
    # Two echoes on the far side, a dotted eighth apart.
    place(v * 0.26, pos + int(round(0.75 * BEAT * SR)), pan, 1 - pan, send=0.7, bus="steel")
    place(v * 0.09, pos + int(round(1.5 * BEAT * SR)), 1 - pan, pan, send=0.8, bus="steel")


def play(phrase, bar, thirds=False):
    """phrase: (beat, note, length, flags). r = roll the note, d = let it droop."""
    for note in phrase:
        beat, m, ln = note[:3]
        flags = note[3] if len(note) > 3 else ""
        beat += bar * 4
        voices = [(m, 1.0, 0.42)]
        if thirds:
            root, chord, scale = chord_at(beat)
            tones = {x % 12 for x in chord} | {root % 12}
            h = below(m, scale, 2)
            if ln >= 1 and h % 12 not in tones:
                h = below(m, scale, 3)
            voices.append((h, 0.6, 0.62))
        for mm, vel, pan in voices:
            if "r" in flags:
                # A roll: quick soft strikes that swell and settle.
                count = int(round((ln - 0.125) / 0.125))
                for k in range(count):
                    swell = 0.6 + 0.4 * np.sin(np.pi * (k + 1) / (count + 1))
                    strike(mm, beat, vel * 0.5 * swell * (1.0 if k % 2 == 0 else 0.8), pan, shift=k * 0.125)
            else:
                strike(mm, beat, vel, pan, droop=0.9 if "d" in flags else 0.0)


FILLS = [(13, 76, .5), (13.5, 79, .5), (14, 81, .5), (14.5, 79, 1),
         (29, 81, .5), (29.5, 79, .5), (30, 77, .5), (30.5, 74, .5), (31, 72, .75)]
TUNE_1 = [(0.5, 76, .5), (1, 79, .5), (1.5, 81, 1), (2.5, 79, .5), (3, 76, 1),
          (4.5, 74, .5), (5, 76, .5), (5.5, 74, 1.5, "r"),
          (8.5, 77, .5), (9, 81, .5), (9.5, 84, 1), (10.5, 81, .5), (11, 79, 1),
          (12.5, 76, .5), (13, 74, .5), (13.5, 76, 2, "r")]
TUNE_2 = [(16.5, 76, .5), (17, 79, .5), (17.5, 81, 1), (18.5, 84, .5), (19, 83, 1),
          (20.5, 79, .5), (21, 76, .5), (22, 73, .75), (22.75, 76, .25), (23, 79, .5), (23.5, 81, 1.5),
          (25.5, 77, .5), (26, 74, .5), (26.5, 77, 1),
          (28.5, 79, .5), (29, 81, .5), (29.5, 84, 1.5, "r")]
HOME = [(16.5, 77, .5), (17, 81, .5), (17.5, 84, 1), (18.5, 86, .5), (19, 84, 1),
        (20.5, 80, .5), (21, 84, .5), (21.5, 80, .5), (22, 77, 2, "r"),
        (24.5, 76, .5), (25, 79, .5), (25.5, 76, 2.5),
        (30.5, 79, .5), (31, 82, .75, "d")]
HOOK = [(0, 84, 1.5), (1.5, 83, .5), (2, 79, 1.5), (3.5, 76, .5),
        (4, 78, 1.5), (5.5, 81, .5), (6, 76, 2, "r"),
        (8, 81, 1.5), (9.5, 79, .5), (10, 76, 1.5), (11.5, 72, .5),
        (12, 74, 1.5), (13.5, 77, .5), (14, 81, 2, "r"),
        (16, 84, 1.5), (17.5, 83, .5), (18, 79, 1.5), (19.5, 76, .5),
        (20, 78, 1.5), (21.5, 81, .5), (22, 84, 2, "r"),
        (24, 81, 1), (25, 77, 1), (26, 79, .5), (26.5, 77, .5), (27, 74, 1),
        (28, 76, 2, "r"), (30.5, 79, .5), (31, 82, 1)]

play(FILLS, SEC_A1)
play(TUNE_1 + TUNE_2, SEC_A2)
play(HOOK, SEC_B, thirds=True)
play(TUNE_1 + HOME, SEC_A3)


# --- the quiet jokes ------------------------------------------------------------
def ding(m):
    """Elevator bell."""
    n = int(2.6 * SR)
    tt = np.arange(n) / SR
    ph = 2 * np.pi * hz(m) * tt
    return np.sin(ph + 2.0 * np.exp(-tt / 0.5) * np.sin(3.5 * ph)) * np.exp(-tt / 0.9)


def cowbell():
    """808-style cowbell, tuned to the fifth and ninth of the key."""
    n = int(0.3 * SR)
    tt = np.arange(n) / SR
    x = sum(np.sin(2 * np.pi * hz(m) * k * tt) / k for m in (79, 86) for k in (1, 3, 5))
    return x * (0.3 * np.exp(-tt * 14) + 0.7 * np.exp(-tt * 60))


place(ding(91) * 0.026, at(SEC_A1 * 4), 0.4, 0.6, send=0.8, bus="fx")
place(ding(88) * 0.022, at(SEC_B * 4), 0.6, 0.4, send=0.8, bus="fx")
place(ding(84) * 0.022, at(SEC_B * 4 + 1), 0.4, 0.6, send=0.8, bus="fx")
CB = cowbell()
for bar in range(SEC_B, SEC_A3):
    for beat in ((1.75, 3.25) if bar % 2 else (1.75,)):
        place(CB * 0.012, at(bar * 4 + beat), 0.7, 0.3, send=0.4, bus="fx")


# --- drums ----------------------------------------------------------------------
def kick():
    n = int(0.4 * SR)
    tt = np.arange(n) / SR
    f = 52 + 110 * np.exp(-tt * 40)
    click = rng.standard_normal(n) * np.exp(-tt * 500) * 0.25
    return (np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9) + click) * 0.32


def hat(open_=False):
    n = int((0.22 if open_ else 0.05) * SR)
    tt = np.arange(n) / SR
    return np.diff(rng.standard_normal(n + 1)) * np.exp(-tt * (16 if open_ else 80)) * 0.038


def shaker():
    n = int(0.09 * SR)
    tt = np.arange(n) / SR
    return np.diff(rng.standard_normal(n + 1)) * np.sin(np.pi * tt / tt[-1]) ** 2 * 0.012


def tap():
    """A muted conga tap: the backbeat, since there is no snare."""
    n = int(0.14 * SR)
    tt = np.arange(n) / SR
    f = 300 * (1 + 0.3 * np.exp(-tt * 60))
    skin = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 32)
    return (skin + rng.standard_normal(n) * np.exp(-tt * 400) * 0.25) * 0.085


def tom(f0):
    """Synth tom with the big 80s pitch dive."""
    n = int(0.45 * SR)
    tt = np.arange(n) / SR
    f = f0 * (1 + 0.9 * np.exp(-tt * 14))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 7) * 0.15


# No snare or clap on purpose: kick, hats, a conga tap and toms only.
K, H, HO, SH, TP = kick(), hat(), hat(True), shaker(), tap()
TOMS = ((3, 220), (3.25, 180), (3.5, 140), (3.75, 110))
for bar in range(BARS):
    b0 = bar * 4
    fill = {7: TOMS[2:], 15: TOMS, 23: TOMS[2:], 31: TOMS}.get(bar, ())
    for kb in (0, 2.5):
        place(K, at(b0 + kb), 0.5, 0.5, send=0.03, bus="drums")
    for tb in (1, 3):
        if not (fill and tb == 3 and len(fill) == 4):
            place(TP, at(b0 + tb), 0.56, 0.44, send=0.25, bus="drums")
    sparse = bar < 4  # the loop restarts on eighths, then the sixteenths come in
    for s in range(16):
        if sparse and s % 2:
            continue
        if fill and s / 4 >= fill[0][0]:
            continue
        vel = (1.0, 0.3, 0.55, 0.3)[s % 4]
        opened = s == 14 and bar % 2 == 1
        place((HO if opened else H) * vel, at(b0 + s / 4), 0.35, 0.65, bus="drums")
        if SEC_B <= bar < SEC_A3:
            place(SH * (1.0 if s % 2 else 0.6), at(b0 + s / 4), 0.7, 0.3, send=0.1, bus="drums")
    for k, (tb, f0) in enumerate(fill):
        pan = 0.3 + 0.13 * k
        place(tom(f0), at(b0 + tb), 1 - pan, pan, send=0.35, bus="drums")


# --- reverb: big, circular ---------------------------------------------------
def ir(seed):
    r = np.random.default_rng(seed)
    n = int(4.0 * SR)
    tt = np.arange(n) / SR
    x = r.standard_normal(n) * np.exp(-tt / 1.1)
    x = np.convolve(x, np.ones(4) / 4, mode="same")
    x[: int(0.035 * SR)] = 0
    return x / np.sqrt(np.sum(x ** 2))


def cconv(x, h):
    hp = np.zeros(N)
    hp[: len(h)] = h
    return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(hp), N)


for name, buf in sorted(STEMS.items()):
    rms = np.sqrt(np.mean(buf ** 2))
    print(f"  {name:6s} rms {20 * np.log10(rms + 1e-12):6.1f} dB  peak {np.max(np.abs(buf)):.3f}", file=sys.stderr)

mix = sum(STEMS.values())
mix = mix + np.stack([cconv(SEND[0], ir(1)), cconv(SEND[1], ir(2))]) * 0.7

# --- slow it down: periodic FFT resample, pitch and tempo drop together ------
M = N * SLOW[1] // SLOW[0]
spec = np.fft.rfft(mix, axis=1)
padded = np.zeros((2, M // 2 + 1), dtype=complex)
padded[:, : spec.shape[1]] = spec
mix = np.fft.irfft(padded, M, axis=1) * (M / N)

# --- stretched tape: slow wow plus flutter (whole cycles per loop) -----------
t = np.arange(M) / SR
loop_s = M / SR
wow = round(0.3 * loop_s) / loop_s
flut = round(6.0 * loop_s) / loop_s
delay = (0.005 * (1 - np.cos(2 * np.pi * wow * t)) + 0.0002 * np.sin(2 * np.pi * flut * t)) * SR
pos = (np.arange(M) - delay) % M
i0 = np.floor(pos).astype(int)
frac = pos - i0
mix = mix[:, i0] * (1 - frac) + mix[:, (i0 + 1) % M] * frac


def shelf(x, lo=35, hi=10000):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = 1 / np.sqrt(1 + (f / hi) ** 4) / np.sqrt(1 + (lo / np.maximum(f, 1e-3)) ** 4)
    g *= 1 + 0.2 * np.exp(-((np.log(np.maximum(f, 1) / 1500)) ** 2) / 0.5)  # small-speaker mids
    return np.fft.irfft(X * g, len(x))


# --- tape saturation: warm and slightly asymmetric, not a clip -------------------
mix /= np.max(np.abs(mix))
mix = np.tanh(DRIVE * (mix + 0.05 * mix ** 2))
mix = np.stack([shelf(ch) for ch in mix])
mix -= mix.mean(axis=1, keepdims=True)
mix *= 0.89 / np.max(np.abs(mix))

pad = int(PAD * SR)
out = np.concatenate([mix[:, -pad:], mix, mix[:, :pad]], axis=1)
pcm = (np.clip(out.T, -1, 1) * 32767).astype("<i2")
with wave.open(sys.argv[1], "wb") as wf:
    wf.setnchannels(2)
    wf.setsampwidth(2)
    wf.setframerate(SR)
    wf.writeframes(pcm.tobytes())
print(f"loop {M} frames ({loop_s:.3f}s), file {out.shape[1] / SR:.3f}s")
