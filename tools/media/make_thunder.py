#!/usr/bin/env python3
"""Thunder of the `tonnerre` event sound, from the real recording (API contract § 11).

The product owner judged the synthetic thunder « pas naturel » and asked for storms that are
never a single isolated hit: rumbles before and after, small sounds that go with it. The only
real thunder we may use is the one of the soundtrack of his `pluie-ville` video (Gemini/Veo,
10 s at 48 kHz): a faint rolling rumble (0.5-3.2 s), a strike at 3.3 s and its rolling rumble,
cut by the end of the clip. This tool turns it into the pieces the app composes into storm
sequences (``orage.parties`` of the catalog):

  1. **Extraction** of the thunder layer (STFT 2048/512, sqrt-Hann): Wiener gain with a
     decision-directed a-priori SNR (alpha 0.96) against a rain profile measured on the
     thunder-free frames (below ~500 Hz: 0.08-0.45 s, before the faint rumble; above: 0.08-
     3.15 s), smoothed over 1/3 octave. Over-subtraction 1 -> 2 and gain floor -10 dB -> -35 dB
     from the low to the high frequencies (rumble kept whole, rain texture removed). During
     the crack (3.22-3.95 s) the strike is kept broadband (no over-subtraction, floor -12 dB);
     elsewhere a time-varying low-pass (900 Hz before the strike, 6 kHz -> 2.5 kHz after the
     crack) removes the residue of the rain where the thunder has nothing. The layer can then
     be laid over the continuous rain bed (``ambiance-pluie-ville``) without doubling the rain.
  2. **Tails completed**: the rumble cut at 10 s goes on with its own material (the rolling
     rumble after the strike, 4.7-9.7 s): grains of 0.7-1.5 s at random places, each played a
     little slower (0.97 -> 0.86: the roll recedes), at the level of a decay curve (a sustain of
     a few seconds, then 2-4 dB/s, a secondary roll sometimes), equal-power cross-fades of
     0.35 s, a low-pass that closes progressively (1.2 kHz -> 300 Hz), a long fade to silence.
     Never an abrupt end.
  3. **Pieces** (``PIECES``), each a one-shot from silence to silence, different slices and
     treatments of the same recording, never synthesis: ``avant`` (soft rumble before the
     flash), ``coup`` (strike and its long rolling rumble), ``coup-proche`` (close strike:
     brighter crack, fuller boom), ``replique`` (weaker aftershock rumble), ``lointain``
     (distant rolling rumble, no crack: low-passed, slow rise). Variety: pitch -4..+2
     semitones (resampling of the thunder layer only: it also stretches the time), distance
     filtering, soft attack, other continuation seeds.
  4. **Level**: one master gain for every piece (``MASTER_GAIN_DB``, from the source scale), so
     the pieces keep their natural relative levels, plus a per-piece offset. The strike body is
     lowered by 6-7 dB against its own roll (``strike_db``, smooth ramps; in the source the
     strike is 13 LU above its roll: the roll could not be heard over the rain bed without a
     strike far louder than the old thunder). A look-ahead limiter (8 ms, 150 ms release: slow
     enough not to distort the low frequencies) keeps the true peak under -2 dBTP before
     encoding (Opus overshoots a crack by up to ~1 dB); if a decoded file is still above -1 dBTP,
     its master is limited a little lower and encoded again.
  5. **Encoding** Ogg Opus 64 kbit/s (plain: one-shots, not loops), Premium:
     ``content/audio/sons/<variant>.ogg``.
  6. **Measurements** on the decoded files: length, integrated loudness, loudest 400 ms, true
     peak, clipped samples, first and last samples (silence), joins (the "click" metric of the
     loops, 5 ms of second-difference energy against its +-50 ms neighbourhood, at every grain
     join, ranked against every window of the file), and how far the rumble emerges over the
     rain bed at the default mix levels (30-300 Hz).

Usage (from the repository root):
  python3 tools/media/make_thunder.py
  python3 tools/media/make_thunder.py --only tonnerre-coup-01
  python3 tools/media/make_thunder.py --check-only
  python3 tools/media/make_thunder.py --wav-dir /tmp/wav --report r.json

Media files are untrusted input: they are only read through ffmpeg. Deterministic: each piece
has its own seed (crc32 of its id).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

from generate_audio import (
    SR,
    decode,
    encode_opus,
    ffmpeg_ebur128,
    k_weighting,
    loudness_lufs,
    todb,
    undb,
    write_wav,
)
from remote_manifest import write_remote_manifest

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "app" / "assets" / "catalog.json"
SOURCE = REPO / "medias-bruts" / "videos" / "pluie-ville.mp4"
BED = REPO / "content" / "audio" / "sons" / "ambiance-pluie-ville.ogg"
FREE_DIR = REPO / "app" / "assets" / "audio" / "sons"
PREMIUM_DIR = REPO / "content" / "audio" / "sons"
SOUND_ID = "tonnerre"
BITRATE = "64k"
COMMENT = ("Eventide thunder - extracted from the soundtrack of the product owner's pluie-ville video "
           "(Gemini/Veo) by tools/media/make_thunder.py")

# Regions of the source (s), measured on pluie-ville.mp4.
RAIN_LOW = (0.08, 0.45)     # rain only, also below 500 Hz (the faint rumble starts at 0.5 s)
RAIN_ALL = (0.08, 3.15)     # rain (+ faint rumble below 500 Hz): rain profile above 500 Hz
CRACK = (3.22, 3.95)        # broadband crack of the strike: kept whole
ROLL = (4.7, 9.7)           # rolling rumble after the strike: material of the continuations
SOURCE_END = 9.85           # the clip ends at 10.0 s; its last 0.15 s are left out

N_FFT, HOP = 2048, 512
XFADE_S = 0.35              # cross-fades between the grains of a continuation
MARGIN_S = 0.05             # resampling margins around each grain
MASTER_GAIN_DB = 9.0        # source scale -> files (one gain for every piece)
STRIKE_BODY = (3.38, 3.52, 4.7, 5.9)  # strike body: gain ramps in, holds, ramps out (s)
CEILING_DBTP = -2.0         # before encoding; Opus overshoots a crack by up to ~1 dB
TRUE_PEAK_MAX_DBTP = -1.0   # after decoding
# Default mix of the storm landscapes (catalog `pluie-ville`): rain bed 70, thunder 50.
BED_LEVEL, THUNDER_LEVEL = 0.70, 0.50


# ----------------------------------------------------------------------------
# Pieces
# ----------------------------------------------------------------------------

@dataclass(frozen=True)
class Piece:
    id: str
    part: str                       # avant, coup, coup-proche, replique, lointain
    span: tuple[float, float]       # slice of the thunder layer (s)
    tail_s: float = 0.0             # continuation after the slice (s), 0: none
    semitones: float = 0.0          # pitch of the thunder layer (resampling: time follows)
    lowpass_hz: float | None = None  # distance filtering...
    lowpass_order: int = 4          # ...and its slope (2: 12 dB/octave)
    attack_s: float = 0.02          # fade-in from silence
    sharpen_db: float = 0.0         # close strike: crack brightened above 1.5 kHz
    boom_db: float = 0.0            # close strike: low boom (below 90 Hz) during the strike
    level_db: float = 0.0           # on top of MASTER_GAIN_DB
    strike_db: float = -7.0         # strike body against its roll (the source has ~13 LU)
    sustain_s: float = 3.0          # continuation: slow decay first...
    sustain_db_s: float = 0.8
    decay_db_s: float = 2.5         # ...then faster
    roll_db: float = 0.0            # continuation: a secondary roll (+dB), 0: none
    lp_close: tuple[float, float] = (1200.0, 300.0)  # continuation low-pass, start -> end
    end_fade_s: float = 2.5         # last fade to silence


PIECES = [
    # Strike at medium distance and its long rolling rumble (strike at 3.3 s, roll to 9.85 s,
    # then the continuation).
    Piece("tonnerre-coup-01", "coup", (3.15, SOURCE_END), tail_s=12.0),
    Piece("tonnerre-coup-02", "coup", (3.15, SOURCE_END), tail_s=13.0, semitones=-2.0,
          sustain_s=4.0, roll_db=4.0),
    Piece("tonnerre-coup-03", "coup", (3.15, SOURCE_END), tail_s=14.0, semitones=-3.5,
          lowpass_hz=1600.0, level_db=-1.5, sustain_s=2.0, decay_db_s=2.0),
    Piece("tonnerre-coup-04", "coup", (3.15, SOURCE_END), tail_s=10.0, semitones=1.0,
          sustain_s=2.5, decay_db_s=3.0, roll_db=3.0),
    # Close strike: brighter crack, a little more boom, less pressed against its roll; the app
    # plays it 0.4 to 1.2 s after the flash.
    Piece("tonnerre-proche-01", "coup-proche", (3.2, SOURCE_END), tail_s=9.0, semitones=1.5,
          sharpen_db=6.0, boom_db=1.5, strike_db=-6.0, decay_db_s=3.0),
    Piece("tonnerre-proche-02", "coup-proche", (3.2, SOURCE_END), tail_s=11.0, semitones=0.5,
          sharpen_db=5.0, boom_db=1.0, strike_db=-6.0, roll_db=3.5),
    Piece("tonnerre-proche-03", "coup-proche", (3.2, SOURCE_END), tail_s=8.0, semitones=2.0,
          sharpen_db=7.0, boom_db=1.0, strike_db=-6.5, sustain_s=2.0, decay_db_s=3.0),
    # Aftershock: the rolling rumble only, weaker, rising softly.
    Piece("tonnerre-replique-01", "replique", (4.75, SOURCE_END), tail_s=7.0, semitones=-1.0,
          lowpass_hz=700.0, attack_s=0.9, level_db=-4.0, sustain_s=2.0),
    Piece("tonnerre-replique-02", "replique", (5.55, SOURCE_END), tail_s=8.0, semitones=-2.5,
          lowpass_hz=550.0, attack_s=1.2, level_db=-3.0, roll_db=3.0),
    Piece("tonnerre-replique-03", "replique", (6.15, SOURCE_END), tail_s=6.0, semitones=0.0,
          lowpass_hz=800.0, attack_s=0.7, level_db=-5.0, sustain_s=1.5, decay_db_s=3.0),
    # Soft rumble before the flash: the faint roll of the recording (0.5-3.2 s), low-passed.
    Piece("tonnerre-avant-01", "avant", (0.45, 3.2), tail_s=3.0, lowpass_hz=450.0, attack_s=0.8,
          level_db=2.0, sustain_s=1.0, decay_db_s=4.0, end_fade_s=2.0),
    Piece("tonnerre-avant-02", "avant", (0.45, 3.2), tail_s=4.0, semitones=-2.5, lowpass_hz=450.0,
          lowpass_order=2, attack_s=1.2, level_db=3.0, sustain_s=1.5, decay_db_s=3.5, end_fade_s=2.0),
    Piece("tonnerre-avant-03", "avant", (6.0, 8.6), tail_s=3.5, semitones=-4.0, lowpass_hz=500.0,
          lowpass_order=2, attack_s=1.6, level_db=-3.0, sustain_s=1.0, decay_db_s=4.0, end_fade_s=2.0),
    # Distant rolling rumble, no crack: the strike heard from far (low-passed, slow rise over
    # the strike, lower pitch).
    Piece("tonnerre-lointain-01", "lointain", (3.3, SOURCE_END), tail_s=10.0, semitones=-3.0,
          lowpass_hz=420.0, lowpass_order=2, attack_s=1.4, level_db=-5.0, sustain_s=3.0, decay_db_s=2.0),
    Piece("tonnerre-lointain-02", "lointain", (3.3, SOURCE_END), tail_s=12.0, semitones=-4.0,
          lowpass_hz=350.0, lowpass_order=2, attack_s=2.0, level_db=-4.0, roll_db=4.0, decay_db_s=2.0),
    Piece("tonnerre-lointain-03", "lointain", (4.6, SOURCE_END), tail_s=9.0, semitones=-1.5,
          lowpass_hz=500.0, lowpass_order=2, attack_s=1.8, level_db=-6.0, sustain_s=2.0),
    Piece("tonnerre-lointain-04", "lointain", (3.3, SOURCE_END), tail_s=8.0, semitones=-2.0,
          lowpass_hz=450.0, lowpass_order=2, attack_s=1.0, level_db=-7.0, decay_db_s=3.0),
]
PARTS = ("avant", "coup", "coup-proche", "replique", "lointain")


# ----------------------------------------------------------------------------
# Signal helpers
# ----------------------------------------------------------------------------

def load(path: Path) -> np.ndarray:
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-map", "0:a:0", "-vn", "-sn", "-dn",
         "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(out, "<f4").reshape(-1, 2).T.astype(np.float64)


WINDOW = np.sqrt(np.hanning(N_FFT + 1)[:-1])   # analysis and synthesis (75 % overlap: exact)


def stft(y: np.ndarray) -> np.ndarray:
    pad = np.pad(y, ((0, 0), (N_FFT, N_FFT)))
    frames = (pad.shape[1] - N_FFT) // HOP + 1
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(frames)[:, None]
    return np.fft.rfft(pad[:, idx] * WINDOW, axis=-1)          # (channels, frames, bins)


def istft(z: np.ndarray, length: int) -> np.ndarray:
    """Weighted overlap-add (N_FFT = 4 x HOP: each output block sums four frames)."""
    k = N_FFT // HOP
    channels, count = z.shape[0], z.shape[1]
    frames = (np.fft.irfft(z, n=N_FFT, axis=-1) * WINDOW).reshape(channels, count, k, HOP)
    out = np.zeros((channels, count + k - 1, HOP))
    norm = np.zeros((count + k - 1, HOP))
    w2 = (WINDOW ** 2).reshape(k, HOP)
    for j in range(k):
        out[:, j:j + count] += frames[:, :, j]
        norm[j:j + count] += w2[j]
    out = out.reshape(channels, -1) / np.maximum(norm.reshape(-1), 1e-9)
    return out[:, N_FFT:N_FFT + length]


def frame_times(frames: int) -> np.ndarray:
    return (np.arange(frames) * HOP - N_FFT / 2) / SR


def ramp(f: np.ndarray, a: float, b: float) -> np.ndarray:
    """0 below ``a`` Hz, 1 above ``b`` Hz, raised cosine on a log axis."""
    u = np.clip((np.log2(np.maximum(f, 1.0)) - np.log2(a)) / (np.log2(b) - np.log2(a)), 0.0, 1.0)
    return 0.5 - 0.5 * np.cos(np.pi * u)


def lowpass_mask(f: np.ndarray, fc: float) -> np.ndarray:
    return 1.0 - ramp(f, fc, 2.0 * fc)


def smooth_octave(p: np.ndarray, f: np.ndarray, fraction: int = 3) -> np.ndarray:
    out = np.empty_like(p)
    for k in range(p.shape[-1]):
        fc = max(f[k], 20.0)
        m = (f >= fc * 2 ** (-0.5 / fraction)) & (f <= fc * 2 ** (0.5 / fraction))
        m[k] = True
        out[..., k] = p[..., m].mean(axis=-1)
    return out


def fft_filter(x: np.ndarray, mag) -> np.ndarray:
    """Zero-phase magnitude filter of a one-shot (zero-padded: no wrap-around)."""
    n = x.shape[-1] + int(0.5 * SR)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x, n=n, axis=-1) * mag(f), n=n, axis=-1)[:, :x.shape[-1]]


def resample(seg: np.ndarray, speed: float) -> np.ndarray:
    """Plays ``seg`` ``speed`` times faster (FFT resampling: pitch and time together)."""
    n = seg.shape[1]
    m = int(round(n / speed))
    spec = np.fft.rfft(seg, axis=-1)
    out = np.zeros((seg.shape[0], m // 2 + 1), complex)
    k = min(spec.shape[1], out.shape[1])
    out[:, :k] = spec[:, :k]
    return np.fft.irfft(out, n=m, axis=-1) * (m / n)


def cosine_in(m: int) -> np.ndarray:
    return 0.5 - 0.5 * np.cos(np.pi * (np.arange(m) + 0.5) / m)


def true_peak(x: np.ndarray, oversample: int = 4) -> float:
    """4x oversampled peak (like generate_audio.true_peak), in power-of-two chunks with 4096
    samples of context on each side; only the chunks whose sample peak is within 2 dB of the
    largest one can hold the true peak."""
    chunk, ctx = 1 << 16, 4096
    hop = chunk - 2 * ctx
    n = x.shape[1]
    pad = np.pad(x, ((0, 0), (ctx, chunk)))
    starts = list(range(0, n, hop))
    peaks = [np.abs(pad[:, s + ctx:s + ctx + hop]).max() for s in starts]
    best = max(peaks)
    out = 0.0
    for s, pk in zip(starts, peaks, strict=True):
        if pk < best * undb(-2.0):
            continue
        spec = np.fft.rfft(pad[:, s:s + chunk], axis=-1)
        up = np.zeros((x.shape[0], oversample * chunk // 2 + 1), complex)
        up[:, :spec.shape[1]] = spec
        y = np.fft.irfft(up, n=oversample * chunk, axis=-1) * oversample
        out = max(out, float(np.abs(y[:, oversample * ctx:oversample * (ctx + hop)]).max()))
    return out


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x)) + 1e-30))


def levels_db(x: np.ndarray, win_s: float, hop_s: float) -> np.ndarray:
    p = np.square(x).mean(axis=0)
    w, h = int(win_s * SR), int(hop_s * SR)
    cs = np.concatenate([[0.0], np.cumsum(p)])
    starts = np.arange(0, max(1, p.size - w + 1), h)
    return 10.0 * np.log10((cs[np.minimum(starts + w, p.size)] - cs[starts]) / w + 1e-20)


# ----------------------------------------------------------------------------
# 1. Extraction of the thunder layer
# ----------------------------------------------------------------------------

def extract(x: np.ndarray) -> tuple[np.ndarray, dict]:
    """Thunder layer of the soundtrack: the rain removed (Wiener gain, decision-directed)."""
    spec = stft(x)
    power = np.abs(spec) ** 2
    t = frame_times(spec.shape[1])
    f = np.fft.rfftfreq(N_FFT, 1.0 / SR)
    low = power[:, (t > RAIN_LOW[0]) & (t < RAIN_LOW[1])].mean(axis=1)
    every = power[:, (t > RAIN_ALL[0]) & (t < RAIN_ALL[1])].mean(axis=1)
    hi = ramp(f, 400.0, 800.0)
    rain = smooth_octave(low * (1.0 - hi) + every * hi, f)
    beta = 1.0 + 1.0 * ramp(f, 800.0, 3000.0)                     # over-subtraction
    floor = undb(-10.0 - 6.0 * ramp(f, 400.0, 1500.0) - 19.0 * ramp(f, 1500.0, 4000.0))
    alpha = 0.96
    gain = np.empty_like(power)
    for ch in range(power.shape[0]):
        prev = np.zeros(f.size)
        for i, ti in enumerate(t):
            crack = CRACK[0] <= ti <= CRACK[1]
            gamma = power[ch, i] / ((1.0 if crack else beta) * rain[ch])
            xi = alpha * prev + (1.0 - alpha) * np.maximum(gamma - 1.0, 0.0)
            g = np.maximum(xi / (1.0 + xi), undb(-12.0) if crack else floor)
            gain[ch, i] = g
            prev = g ** 2 * gamma
    # Where the thunder has nothing: before the strike only a low rumble, after the crack the
    # roll lives below ~2 kHz.
    shape = np.ones((t.size, f.size))
    for i, ti in enumerate(t):
        if ti < CRACK[0]:
            shape[i] = lowpass_mask(f, 900.0)
        elif ti > CRACK[1]:
            u = min(1.0, (ti - CRACK[1]) / 1.0)
            shape[i] = lowpass_mask(f, 6000.0 * (1.0 - u) + 2500.0 * u)
    layer = istft(spec * gain * shape[None], x.shape[1])
    return layer, extraction_report(x, layer)


BANDS = [(20, 60), (60, 120), (120, 250), (250, 500), (500, 1000), (1000, 3000), (3000, 8000), (8000, 16000)]


def band_levels(y: np.ndarray, a: float, b: float) -> list[float]:
    """Energy (dB) of each band of BANDS over [a, b] s (Hann window)."""
    seg = y[:, int(a * SR):int(b * SR)]
    n = seg.shape[1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    s = np.abs(np.fft.rfft(seg * np.hanning(n), axis=-1)) ** 2
    return [float(10.0 * np.log10(s[:, (f >= lo) & (f < hi)].sum() / n + 1e-30)) for lo, hi in BANDS]


def extraction_report(x: np.ndarray, layer: np.ndarray) -> dict:
    """What the extraction keeps (layer - source, dB per band) in each region of the source."""
    regions = {"rain_only": RAIN_LOW, "faint_rumble": (0.5, 3.15), "crack": (3.25, 3.9),
               "strike": (3.9, 5.0), "roll": (6.0, 9.8)}
    out = {"bands_hz": [f"{lo}-{hi}" for lo, hi in BANDS]}
    for name, (a, b) in regions.items():
        src, lay = band_levels(x, a, b), band_levels(layer, a, b)
        out[name] = [round(lv - sv, 1) for sv, lv in zip(src, lay, strict=True)]
    # Musical-noise proxy in the rain-only frames (300-1500 Hz, where the layer keeps a residue):
    # 99th percentile over median of the per-bin power; Gaussian noise gives about 8 dB.
    spec_x, spec_l = stft(x), stft(layer)
    t = frame_times(spec_x.shape[1])
    f = np.fft.rfftfreq(N_FFT, 1.0 / SR)
    sel = (t > RAIN_LOW[0]) & (t < RAIN_LOW[1])
    band = (f >= 300) & (f < 1500)

    def spread(z):
        p = np.abs(z[:, sel][:, :, band]) ** 2
        return round(float(10.0 * np.log10(np.percentile(p, 99) / np.median(p))), 1)

    out["rain_only_spread_db"] = {"source": spread(spec_x), "layer": spread(spec_l)}
    out["rain_only_residual_db"] = round(float(10.0 * np.log10(
        np.mean(np.abs(spec_l[:, sel]) ** 2) / np.mean(np.abs(spec_x[:, sel]) ** 2))), 1)
    return out


# ----------------------------------------------------------------------------
# 2. Continuation of a rolling rumble
# ----------------------------------------------------------------------------

def continuation(pool: np.ndarray, seconds: float, start_rms: float, piece: Piece,
                 rng: np.random.Generator) -> tuple[np.ndarray, list[int]]:
    """``seconds`` of rolling rumble made of grains of ``pool``, starting at ``start_rms`` and
    decaying (sustain, then faster, a secondary roll sometimes), the low-pass closing
    progressively, a long fade to silence. Its first XFADE_S overlap the end of the real tail
    (they fade in while it fades out). Returns the signal and the grain joins (samples)."""
    n = int(seconds * SR)
    x = int(XFADE_S * SR)
    margin = int(MARGIN_S * SR)
    out = np.zeros((2, n + x))
    u = (np.arange(x) + 0.5) / x
    fade_in, fade_out = np.sin(0.5 * np.pi * u), np.cos(0.5 * np.pi * u)
    roll_at = rng.uniform(0.3, 0.6) * seconds

    def level_db(ts: float) -> float:
        db = -piece.sustain_db_s * min(ts, piece.sustain_s) - piece.decay_db_s * max(0.0, ts - piece.sustain_s)
        if piece.roll_db:
            db += piece.roll_db * np.exp(-0.5 * ((ts - roll_at) / 0.9) ** 2)
        return db

    joins, recent, at = [], [], 0
    while at < n:
        length = int(rng.uniform(0.7, 1.5) * SR)
        progress = min(1.0, at / max(n, 1))
        speed = (0.97 + (0.86 - 0.97) * progress) * rng.uniform(0.985, 1.015)
        span = int(np.ceil((length + x) * speed))
        need = span + 2 * margin + 2
        if need > pool.shape[1]:
            raise SystemExit(f"{piece.id}: rumble pool too short for the grains")
        src = None
        for strict in (2, 1, 0):
            for _ in range(200):
                cand = int(rng.integers(margin, pool.shape[1] - margin - span))
                if any(abs(cand - r) < span for r in recent[-strict:] if strict):
                    continue
                src = cand
                break
            if src is not None:
                break
        recent.append(src)
        seg = pool[:, src - margin: src + span + margin].copy()
        taper = np.hanning(2 * margin + 2)[1:-1]
        seg[:, :margin] *= taper[:margin]
        seg[:, -margin:] *= taper[margin:]
        res = resample(seg, speed)
        lead = int(round(margin / speed))
        grain = res[:, lead: lead + length + x].copy()
        if rng.random() < 0.5:
            grain = grain[::-1]
        mid = (at + length / 2) / SR
        grain *= start_rms * undb(level_db(mid) + rng.uniform(-2.5, 1.5)) / rms(grain)
        grain[:, :x] *= fade_in
        grain[:, -x:] *= fade_out
        end = min(out.shape[1], at + grain.shape[1])
        out[:, at:end] += grain[:, :end - at]
        if at > 0:
            joins.append(at + x // 2)
        at += length
    # The low-pass closes as the roll recedes.
    spec = stft(out)
    t = frame_times(spec.shape[1])
    f = np.fft.rfftfreq(N_FFT, 1.0 / SR)
    first, last = piece.lp_close
    for i, ti in enumerate(t):
        p = np.clip(ti / max(seconds, 1e-9), 0.0, 1.0)
        spec[:, i] *= lowpass_mask(f, first * (last / first) ** p)
    out = istft(spec, out.shape[1])
    fade = int(min(piece.end_fade_s, seconds * 0.5) * SR)
    out[:, -fade:] *= cosine_in(fade)[::-1]
    return out, joins


# ----------------------------------------------------------------------------
# 3. Pieces
# ----------------------------------------------------------------------------

def make_piece(layer: np.ndarray, piece: Piece) -> tuple[np.ndarray, dict]:
    rng = np.random.default_rng(zlib.crc32(piece.id.encode()))
    a, b = (int(s * SR) for s in piece.span)
    seg = layer[:, a:b] * strike_envelope(piece.span[0], b - a, piece.strike_db)
    joins = []
    if piece.tail_s > 0:
        pool = layer[:, int(ROLL[0] * SR):int(ROLL[1] * SR)]
        if piece.part == "avant" and piece.span[1] <= 3.3:
            pool = layer[:, int(0.5 * SR):int(3.15 * SR)]          # the faint roll itself
        start = rms(seg[:, -int(2.0 * SR):])
        cont, cjoins = continuation(pool, piece.tail_s, start, piece, rng)
        x = int(XFADE_S * SR)
        u = (np.arange(x) + 0.5) / x
        seg[:, -x:] *= np.cos(0.5 * np.pi * u)
        cont[:, :x] += seg[:, -x:]
        joins = [seg.shape[1] - x // 2] + [seg.shape[1] - x + j for j in cjoins]
        seg = np.concatenate([seg[:, :-x], cont], axis=1)
    else:
        fade = int(piece.end_fade_s * SR)
        seg[:, -fade:] *= cosine_in(fade)[::-1]
    onset = max(0, int((CRACK[0] - piece.span[0]) * SR))
    if piece.sharpen_db or piece.boom_db:
        seg = sharpen(seg, onset, piece)
    if piece.lowpass_hz:
        order = 2 * piece.lowpass_order
        seg = fft_filter(seg, lambda f: (1.0 + (f / piece.lowpass_hz) ** order) ** -0.5)
    speed = 2.0 ** (piece.semitones / 12.0)
    if speed != 1.0:
        seg = resample(seg, speed)
        joins = [int(round(j / speed)) for j in joins]
    att = max(1, int(piece.attack_s * SR))
    seg[:, :att] *= cosine_in(att)
    seg = seg * undb(MASTER_GAIN_DB + piece.level_db)
    # 20 ms of silence on both sides: the decoder starts and ends on silence.
    pad = int(0.02 * SR)
    seg = np.pad(seg, ((0, 0), (pad, pad)))
    joins = [j + pad for j in joins]
    before = float(todb(true_peak(seg)))
    seg = peak_limit(seg, CEILING_DBTP)
    return seg, {"joins": joins, "limiter_db": round(max(0.0, before - float(todb(true_peak(seg)))), 1)}


BLOCK = 48                  # 1 ms blocks for the dynamics


def _blocks(x: np.ndarray, reduce) -> np.ndarray:
    m = -(-x.shape[1] // BLOCK)
    pad = np.pad(x, ((0, 0), (0, m * BLOCK - x.shape[1])))
    return reduce(pad.reshape(x.shape[0], m, BLOCK))


def peak_limit(x: np.ndarray, ceiling_dbtp: float, look_ms: int = 8, release_ms: float = 150.0) -> np.ndarray:
    """Look-ahead peak limiter for one-shots: gain under what each peak needs over +-look_ms
    (raised-cosine attack), 150 ms release; slow enough for the low frequencies of a thunder
    not to be distorted. Repeated until the 4x oversampled true peak is under the ceiling."""
    ceiling = undb(ceiling_dbtp)
    for _ in range(12):
        if todb(true_peak(x)) <= ceiling_dbtp:
            return x
        need = np.minimum(1.0, ceiling / np.maximum(_blocks(np.abs(x), lambda b: b.max(axis=(0, 2))), 1e-12))
        m = need.copy()
        for k in range(1, look_ms + 1):
            m[:-k] = np.minimum(m[:-k], need[k:])
            m[k:] = np.minimum(m[k:], need[:-k])
        r = np.empty_like(m)
        g, up = 1.0, 1.0 - np.exp(-1.0 / release_ms)
        for i, v in enumerate(m):
            g = min(v, g + (1.0 - g) * up)
            r[i] = g
        kern = np.hanning(2 * look_ms + 3)[1:-1]
        kern /= kern.sum()
        smooth = np.minimum(np.convolve(np.pad(r, look_ms, mode="edge"), kern, mode="valid"), r)
        x = x * np.repeat(smooth, BLOCK)[:x.shape[1]]
        ceiling *= undb(-0.2)
    return x


def strike_envelope(start_s: float, n: int, db: float) -> np.ndarray:
    """Gain (linear, per sample) that lowers the strike body by ``db`` against its roll, with
    smooth raised-cosine ramps (STRIKE_BODY, source time). The crack's own dynamics are kept;
    only its level against the long roll changes, so that the roll can be heard over the rain
    bed without the strike being far louder than the old thunder."""
    t = start_s + np.arange(n) / SR
    a, b, c, d = STRIKE_BODY
    u = np.clip((t - a) / (b - a), 0.0, 1.0) * (t < c) + np.clip((d - t) / (d - c), 0.0, 1.0) * (t >= c)
    w = 0.5 - 0.5 * np.cos(np.pi * u)
    return undb(db * w)


def sharpen(seg: np.ndarray, onset: int, piece: Piece) -> np.ndarray:
    """Close strike: the crack brightened (above 1.5 kHz) and the boom fuller (below 90 Hz),
    during the first moments of the strike only (STFT gains, smooth in time)."""
    spec = stft(seg)
    t = frame_times(spec.shape[1])
    f = np.fft.rfftfreq(N_FFT, 1.0 / SR)
    t0 = onset / SR
    bright = ramp(f, 1500.0, 3000.0) * (1.0 - ramp(f, 7000.0, 12000.0))
    boom = 1.0 - ramp(f, 90.0, 180.0)
    for i, ti in enumerate(t):
        u = ti - t0
        crack = np.exp(-0.5 * ((u - 0.3) / 0.25) ** 2) if u > -0.5 else 0.0
        body = np.exp(-0.5 * ((u - 0.8) / 0.6) ** 2) if u > -0.5 else 0.0
        spec[:, i] *= undb(piece.sharpen_db * crack * bright + piece.boom_db * body * boom)
    return istft(spec, seg.shape[1])


# ----------------------------------------------------------------------------
# 4. Measurements
# ----------------------------------------------------------------------------

def momentary_max_lufs(x: np.ndarray) -> float:
    """Loudest 400 ms block (BS.1770 momentary loudness)."""
    n = x.shape[-1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    y = np.fft.irfft(np.fft.rfft(x, axis=-1) * k_weighting(f), n=n, axis=-1)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    cs = np.concatenate([np.zeros((2, 1)), np.cumsum(y ** 2, axis=1)], axis=1)
    starts = np.arange(0, max(1, n - blk + 1), hop)
    z = ((cs[:, starts + blk] - cs[:, starts]) / blk).sum(axis=0)
    return float(-0.691 + 10.0 * np.log10(z.max() + 1e-20))


def click_profile(y: np.ndarray, win: int = 240, ctx: int = 10) -> np.ndarray:
    """Per 5 ms window: second-difference energy against the median of its +-50 ms (dB)."""
    hf = np.square(y[:, 2:] - 2.0 * y[:, 1:-1] + y[:, :-2]).sum(axis=0)
    m = hf.size // win
    e = hf[:m * win].reshape(m, win).sum(axis=1) + 1e-30
    pad = np.pad(e, ctx, mode="edge")
    neigh = np.stack([pad[ctx + k: ctx + k + m] for k in range(-ctx, ctx + 1) if k != 0])
    return 10.0 * np.log10(e / np.median(neigh, axis=0))


def join_clicks(y: np.ndarray, joins: list[int]) -> dict:
    """The click metric at each join, against every window of the file (rank, %)."""
    win = 240
    r = click_profile(y, win)
    if not joins:
        return {"count": 0}
    at = [r[min(r.size - 1, max(0, (j - 1) // win))] for j in joins]
    worst = max(at)
    ranks = [float((r < v).mean() * 100) for v in at]
    return {"count": len(joins), "worst_db": round(float(worst), 2),
            "worst_rank_pct": round(max(ranks), 1), "median_rank_pct": round(float(np.median(ranks)), 1),
            "file_p99_db": round(float(np.percentile(r, 99)), 2)}


EMERGENCE_BANDS = {"low": (30.0, 250.0), "speaker": (250.0, 1500.0)}


def bed_emergence(y: np.ndarray, bed: np.ndarray) -> dict:
    """How far the thunder rises over the rain bed at the default mix levels (bed 70, thunder
    50), 250 ms windows: level of bed + thunder against the bed alone, in the low band (30-250
    Hz: earphones) and in the band a phone speaker plays (250-1500 Hz)."""
    n = y.shape[1]
    reps = int(np.ceil(n / bed.shape[1]))
    b = np.tile(bed, (1, reps))[:, :n] * BED_LEVEL
    mix = b + y * THUNDER_LEVEL
    f = np.fft.rfftfreq(n, 1.0 / SR)
    fm, fb = np.fft.rfft(mix, axis=-1), np.fft.rfft(b, axis=-1)
    out = {"strike_over_bed_lu": round(momentary_max_lufs(y * THUNDER_LEVEL) - loudness_lufs(bed * BED_LEVEL), 1)}
    for name, (lo, hi) in EMERGENCE_BANDS.items():
        m = (f >= lo) & (f < hi)
        e = (levels_db(np.fft.irfft(fm * m, n=n, axis=-1), 0.25, 0.25)
             - levels_db(np.fft.irfft(fb * m, n=n, axis=-1), 0.25, 0.25))
        above3 = np.flatnonzero(e >= 3.0)
        above1 = np.flatnonzero(e >= 1.0)
        out[name] = {"max_db": round(float(e.max()), 1),
                     "above_3db_s": round(float(above3.size * 0.25), 2),
                     "last_above_3db_s": round(float((above3[-1] + 1) * 0.25), 2) if above3.size else 0.0,
                     "last_above_1db_s": round(float((above1[-1] + 1) * 0.25), 2) if above1.size else 0.0}
    return out


def measure(piece: Piece, dest: Path, joins: list[int] | None, bed: np.ndarray | None) -> dict:
    y = decode(dest)
    i_lufs, _ = ffmpeg_ebur128(dest)
    peak = np.abs(y).max(axis=0)
    row = {
        "id": piece.id, "part": piece.part, "path": str(dest.relative_to(REPO)), "bytes": dest.stat().st_size,
        "seconds": round(y.shape[1] / SR, 2), "lufs": round(loudness_lufs(y, circular=False), 2),
        "ffmpeg_lufs": i_lufs, "momentary_max_lufs": round(momentary_max_lufs(y), 1),
        "decoded_true_peak_dbtp": round(float(todb(true_peak(y))), 2),
        "clipped_samples": int((np.abs(y) >= 1.0).sum()),
        "first_10ms_peak_dbfs": round(float(todb(peak[:int(0.01 * SR)].max())), 1),
        "last_50ms_peak_dbfs": round(float(todb(peak[-int(0.05 * SR):].max())), 1),
    }
    if joins is not None:
        row["joins"] = join_clicks(y, joins)
    if bed is not None:
        row["over_bed"] = bed_emergence(y, bed)
    return row


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------

def check_catalog(catalog: dict) -> bool:
    """The catalog lists exactly these pieces (``variantes``, ``orage.parties``). Returns the
    sound's ``gratuit``."""
    sound = next((s for s in catalog["sons"] if s["id"] == SOUND_ID), None)
    if sound is None or sound.get("lecture") != "evenements":
        raise SystemExit(f"{SOUND_ID}: not an event sound of the catalog")
    ids = [p.id for p in PIECES]
    if sorted(sound.get("variantes", [])) != sorted(ids):
        raise SystemExit(f"{SOUND_ID}: catalog `variantes` differ from PIECES")
    parts = sound.get("orage", {}).get("parties", {})
    for part in PARTS:
        want = sorted(p.id for p in PIECES if p.part == part)
        if sorted(parts.get(part, [])) != want:
            raise SystemExit(f"{SOUND_ID}: catalog `orage.parties.{part}` differs from PIECES")
    return bool(sound.get("gratuit"))


def destination(piece: Piece, free: bool) -> Path:
    return (FREE_DIR if free else PREMIUM_DIR) / f"{piece.id}.ogg"


def remove_stale(free: bool) -> list[str]:
    """Variants of the thunder no longer made (the synthetic tonnerre-01..10, any piece
    removed from PIECES, a copy on the other side of the free/Premium line)."""
    keep = {destination(p, free) for p in PIECES}
    removed = []
    for folder in (FREE_DIR, PREMIUM_DIR):
        for old in sorted(folder.glob(f"{SOUND_ID}-*.ogg")):
            if old not in keep:
                old.unlink()
                removed.append(str(old.relative_to(REPO)))
    return removed


def build(layer: np.ndarray, piece: Piece, dest: Path, bed: np.ndarray | None, wav_dir: Path | None) -> dict:
    """Makes, encodes and measures one piece; if Opus overshoots -1 dBTP, the master is
    limited a little lower and encoded again."""
    x, info = make_piece(layer, piece)
    joins = info.pop("joins")
    for _ in range(4):
        encode_opus(x.astype(np.float32), dest, f"Eventide - {piece.id}", plain=True, bitrate=BITRATE,
                    comment=COMMENT)
        row = measure(piece, dest, joins, bed)
        over = row["decoded_true_peak_dbtp"] - (TRUE_PEAK_MAX_DBTP - 0.05)
        if over <= 0:
            break
        x = peak_limit(x, float(todb(true_peak(x))) - over - 0.2)
    row.update(info)
    row["master_true_peak_dbtp"] = round(float(todb(true_peak(x))), 2)
    if wav_dir:
        write_wav(x.astype(np.float32), wav_dir / f"{piece.id}.wav")
    return row


def print_row(row: dict) -> None:
    j = row.get("joins", {})
    ob = row.get("over_bed")
    line = (f"{row['id']:<21} {row['seconds']:5.1f} s {row['bytes'] / 1024:4.0f} KiB {row['lufs']:6.1f} LUFS "
            f"(M max {row['momentary_max_lufs']:6.1f}) TP {row['decoded_true_peak_dbtp']:5.1f} clip {row['clipped_samples']}"
            f" ends {row['first_10ms_peak_dbfs']:.0f}/{row['last_50ms_peak_dbfs']:.0f} dBFS")
    if j.get("count"):
        line += (f" joins {j['count']}: median rank {j['median_rank_pct']:.0f} %, worst {j['worst_db']:+.1f} dB "
                 f"({j['worst_rank_pct']:.0f} %, file p99 {j['file_p99_db']:+.1f})")
    if "limiter_db" in row:
        line += f" lim {row['limiter_db']:.1f}"
    if ob:
        line += (f" | strike {ob['strike_over_bed_lu']:+.1f} LU; low +{ob['low']['max_db']:.1f} dB "
                 f">=3 until {ob['low']['last_above_3db_s']:.1f} s; speaker +{ob['speaker']['max_db']:.1f} dB "
                 f">=3 until {ob['speaker']['last_above_3db_s']:.1f} s, >=1 until {ob['speaker']['last_above_1db_s']:.1f} s")
    print(line)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--only", nargs="*", help="piece ids to (re)build")
    ap.add_argument("--check-only", action="store_true", help="re-measure the existing files")
    ap.add_argument("--wav-dir", type=Path, help="also write the float WAV masters and the thunder layer here")
    ap.add_argument("--report", type=Path, help="write the measurements as JSON")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    free = check_catalog(catalog)
    pieces = [p for p in PIECES if not args.only or p.id in args.only]
    if args.only and len(pieces) != len(args.only):
        raise SystemExit("unknown id in --only")
    bed = decode(BED) if BED.exists() else None
    t0 = time.time()
    report: dict = {"master_gain_db": MASTER_GAIN_DB, "pieces": []}
    layer = None
    if not args.check_only:
        layer, report["extraction"] = extract(load(SOURCE))
        if args.wav_dir:
            write_wav(layer.astype(np.float32), args.wav_dir / "thunder-layer.wav")
    for piece in pieces:
        dest = destination(piece, free)
        if layer is None:
            row = measure(piece, dest, None, bed)
        else:
            row = build(layer, piece, dest, bed, args.wav_dir)
        row["spec"] = {k: v for k, v in asdict(piece).items() if k not in ("id", "part")}
        report["pieces"].append(row)
        print_row(row)
    if not args.check_only:
        for old in remove_stale(free):
            print(f"removed {old}")
        manifest = write_remote_manifest()
        print(f"remote.json: sons {manifest['sons']}")
        ext = report["extraction"]
        print("extraction (layer - source, dB per band " + ", ".join(ext["bands_hz"]) + "):")
        for name in ("rain_only", "faint_rumble", "crack", "strike", "roll"):
            print(f"  {name:<13} " + " ".join(f"{v:6.1f}" for v in ext[name]))
        print(f"  rain-only residual {ext['rain_only_residual_db']} dB; spread 300-1500 Hz "
              f"{ext['rain_only_spread_db']}")
    print(f"done in {time.time() - t0:.0f} s")
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    bad = [r["id"] for r in report["pieces"]
           if r["clipped_samples"] or r["decoded_true_peak_dbtp"] > TRUE_PEAK_MAX_DBTP]
    if bad:
        print("WARNING: true peak above -1 dBTP or clipped: " + ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
