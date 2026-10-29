#!/usr/bin/env python3
"""Generate synthetic, seamlessly looping placeholder audio for Eventide.

Every sound is synthesised from scratch with numpy (no recordings, no samples),
so the output carries no third-party rights. These files are placeholders that
exercise the audio engine (looping, layering, fades) until licensed content
replaces them.

Sounds played by events (catalog `lecture: evenements`, API contract § 11) are
not loops and are not made here: the variants of `tonnerre` come from the real
thunder of the `pluie-ville` soundtrack (make_thunder.py). Landscape ambiances
(catalog `paysage`) come from the landscape videos (make_ambiance.py). Both are
skipped here.

Seamless looping
----------------
Each item is rendered on a *circular* time axis of N samples, so sample N-1 is
followed by sample 0:
  * noise beds are built in the frequency domain (complex Gaussian spectrum
    shaped by a magnitude curve, then inverse real FFT): periodic by
    construction;
  * filters and reverbs are circular convolutions (FFT products), i.e. the
    steady-state response of the looping signal, including reverb tails that
    wrap around;
  * discrete events (chirps, hoots, crackles, notes...) are added modulo N, so
    an event crossing the end continues at the start;
  * continuous oscillators and LFOs use an integer number of cycles per loop.

Loudness
--------
Integrated loudness follows ITU-R BS.1770-4 (K-weighting, 400 ms blocks with
75 % overlap, absolute gate -70 LUFS, relative gate -10 LU), evaluated on the
circular signal. Each item is peak-normalised to -1 dBFS, then gained to
-23 LUFS; if the 4x-oversampled true peak exceeds -1 dBTP a gentle circular
look-ahead limiter is applied.

Encoding: Ogg Opus through ffmpeg/libopus, 64 kbit/s stereo, -application audio,
20 ms frames, then re-muxed so that the file decodes to exactly N samples with a
seamless join (see encode_opus). The script then decodes each file back,
concatenates two copies and measures the discontinuity at the join against the
rest of the file.

Usage (from the repository root):
  python3 tools/media/generate_audio.py               # everything
  python3 tools/media/generate_audio.py --only vent harpe
  python3 tools/media/generate_audio.py --check-only  # re-measure existing .ogg
  python3 tools/media/generate_audio.py --wav-dir /tmp/wav  # also keep float WAVs
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

from remote_manifest import write_remote_manifest

SR = 48_000
TARGET_LUFS = -23.0
PEAK_NORM_DBFS = -1.0
TRUE_PEAK_MAX_DBTP = -1.0
OPUS_BITRATE = "64k"
SQRT2 = np.sqrt(2.0)

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "app" / "assets" / "catalog.json"
FREE_ROOT = REPO / "app" / "assets" / "audio"
PREMIUM_ROOT = REPO / "content" / "audio"
COMMENT = ("Eventide synthetic placeholder - generated from scratch by "
           "tools/media/generate_audio.py - no samples, no third-party rights")


# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

def undb(d):
    return 10.0 ** (np.asarray(d, dtype=float) / 20.0)


def todb(x):
    return 20.0 * np.log10(np.maximum(x, 1e-12))


def rms(x):
    return float(np.sqrt(np.mean(np.square(x))))


def unit_rms(x):
    r = rms(x)
    return x / r if r > 0 else x


def loguniform(rng, lo, hi):
    return float(np.exp(rng.uniform(np.log(lo), np.log(hi))))


NOTE_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def hz(name: str) -> float:
    """Note name to frequency: 'A4' -> 440, 'F#3', 'Bb2'."""
    i, acc = 1, 0
    while i < len(name) and name[i] in "#b":
        acc += 1 if name[i] == "#" else -1
        i += 1
    midi = 12 * (int(name[i:]) + 1) + NOTE_INDEX[name[0]] + acc
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def pan_gains(pan):
    """Constant-power pan law, unity gain per channel at the centre."""
    a = (np.clip(pan, -1.0, 1.0) + 1.0) * np.pi / 4.0
    return np.cos(a) * SQRT2, np.sin(a) * SQRT2


# --- magnitude shapes (zero phase, used to colour noise) ---------------------

def tilt(f, db_per_octave, ref=1000.0):
    return (np.maximum(f, 10.0) / ref) ** (db_per_octave / 6.0206)


def lpm(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def hpm(f, fc, order=2):
    r = (f / fc) ** (2 * order)
    return np.sqrt(r / (1.0 + r))


def bump(f, fc, gain_db, octaves=1.0):
    """Smooth bell on a log-frequency axis (gain_db at fc)."""
    x = np.log2(np.maximum(f, 1.0) / fc) / octaves
    return undb(gain_db * np.exp(-2.0 * x * x))


# --- causal biquads (RBJ cookbook) evaluated on FFT bins ---------------------

def biquad(f, kind, fc, q=0.707, gain_db=0.0):
    w0 = 2.0 * np.pi * fc / SR
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2.0 * q)
    a_ = 10.0 ** (gain_db / 40.0)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "bp":
        b = [alpha, 0.0, -alpha]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "peak":
        b = [1 + alpha * a_, -2 * cw, 1 - alpha * a_]
        a = [1 + alpha / a_, -2 * cw, 1 - alpha / a_]
    elif kind in ("lowshelf", "highshelf"):
        al = sw / 2.0 * SQRT2
        s = 2.0 * np.sqrt(a_) * al
        if kind == "lowshelf":
            b = [a_ * ((a_ + 1) - (a_ - 1) * cw + s), 2 * a_ * ((a_ - 1) - (a_ + 1) * cw),
                 a_ * ((a_ + 1) - (a_ - 1) * cw - s)]
            a = [(a_ + 1) + (a_ - 1) * cw + s, -2 * ((a_ - 1) + (a_ + 1) * cw),
                 (a_ + 1) + (a_ - 1) * cw - s]
        else:
            b = [a_ * ((a_ + 1) + (a_ - 1) * cw + s), -2 * a_ * ((a_ - 1) + (a_ + 1) * cw),
                 a_ * ((a_ + 1) + (a_ - 1) * cw - s)]
            a = [(a_ + 1) - (a_ - 1) * cw + s, 2 * ((a_ - 1) - (a_ + 1) * cw),
                 (a_ + 1) - (a_ - 1) * cw - s]
    else:
        raise ValueError(kind)
    z1 = np.exp(-2j * np.pi * f / SR)
    z2 = z1 * z1
    return (b[0] + b[1] * z1 + b[2] * z2) / (a[0] + a[1] * z1 + a[2] * z2)


def chain(f, specs):
    h = np.ones_like(f, dtype=complex)
    for s in specs:
        h = h * biquad(f, *s)
    return h


def cfilter(x, specs):
    """Circular (periodic steady-state) filtering of a loop."""
    n = x.shape[-1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x, axis=-1) * chain(f, specs), n=n, axis=-1)


def efilter(x, specs, tail=0.08):
    """Filter a one-shot event (zero-padded so the ringing has room)."""
    n = x.shape[-1] + int(tail * SR)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x, n=n, axis=-1) * chain(f, specs), n=n, axis=-1)


def emag(x, mag_fn):
    """Colour a one-shot event with a zero-phase magnitude curve mag_fn(f)."""
    n = x.shape[-1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x, axis=-1) * mag_fn(f), n=n, axis=-1)


def add_circular(buf, start, sig):
    """buf[:, (start + i) % N] += sig[:, i] (events longer than N fold over)."""
    n, m = buf.shape[1], sig.shape[1]
    start %= n
    pos = 0
    while pos < m:
        i = (start + pos) % n
        k = min(n - i, m - pos)
        buf[:, i:i + k] += sig[:, pos:pos + k]
        pos += k


def env_ar(m, attack, release):
    """Raised-cosine attack/release envelope over m samples."""
    e = np.ones(m)
    a = min(max(1, int(attack * SR)), m // 2)
    r = min(max(1, int(release * SR)), m - a)
    e[:a] = 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / a)
    e[m - r:] = 0.5 + 0.5 * np.cos(np.pi * np.arange(r) / r)
    return e


# ----------------------------------------------------------------------------
# Circular canvas
# ----------------------------------------------------------------------------

class Canvas:
    """A stereo loop of `seconds`; the last sample is followed by the first."""

    def __init__(self, seconds: float, seed: int):
        self.seconds = float(seconds)
        self.n = int(round(seconds * SR))
        if abs(self.n - seconds * SR) > 1e-6:
            raise ValueError("loop length must be a whole number of samples")
        self.rng = np.random.default_rng(seed)
        self.f = np.fft.rfftfreq(self.n, 1.0 / SR)
        self.t = np.arange(self.n) / SR

    def zeros(self):
        return np.zeros((2, self.n))

    def noise(self, mag, corr=0.5):
        """Periodic stereo noise with amplitude spectrum `mag` (unit RMS)."""
        rng = self.rng

        def draw(k):
            spec = mag * (rng.standard_normal((k, mag.size)) + 1j * rng.standard_normal((k, mag.size)))
            spec[:, 0] = 0.0
            return np.fft.irfft(spec, n=self.n, axis=-1)

        x = np.sqrt(corr) * draw(1)[0] + np.sqrt(1.0 - corr) * draw(2)
        return unit_rms(x)

    def drift(self, max_hz, lo=0.0, hi=1.0):
        """Smooth periodic random curve (content below max_hz) mapped to [lo, hi]."""
        band = (self.f > 0) & (self.f <= max(max_hz, self.f[1]))
        k = int(band.sum())
        spec = np.zeros(self.f.size, dtype=complex)
        spec[band] = (self.rng.standard_normal(k) + 1j * self.rng.standard_normal(k)) / np.sqrt(
            self.f[band] / self.f[band][0])
        x = np.fft.irfft(spec, n=self.n)
        x = (x - x.min()) / (x.max() - x.min() + 1e-12)
        return lo + (hi - lo) * x

    def cycles(self, freq_hz):
        """Nearest whole number of cycles per loop for a continuous oscillator."""
        return max(1, int(round(freq_hz * self.seconds)))

    def lfo(self, cycles, phase=0.0):
        return np.sin(2.0 * np.pi * cycles * np.arange(self.n) / self.n + phase)

    def qhz(self, freq_hz):
        """Quantise a frequency so it completes an integer number of cycles per loop."""
        return self.cycles(freq_hz) / self.seconds

    def place(self, buf, t0, sig, pan=0.0, gain=1.0, itd=True):
        """Add a mono (M,) or stereo (2, M) event at time t0 (seconds, wraps)."""
        gl, gr = pan_gains(pan)
        if sig.ndim == 1:
            d = int(round(abs(pan) * 0.00035 * SR)) if itd else 0
            st = np.zeros((2, sig.size + d))
            if pan >= 0:
                st[0, d:] = sig * gl
                st[1, :sig.size] = sig * gr
            else:
                st[0, :sig.size] = sig * gl
                st[1, d:] = sig * gr
        else:
            st = sig * np.array([[gl], [gr]])
        add_circular(buf, int(round(t0 * SR)), st * gain)

    def impulses(self, rate, alpha=2.0, cap=8.0, spread=1.0):
        """Random stereo impulse train (Pareto amplitudes), uniform on the circle."""
        rng = self.rng
        k = rng.poisson(rate * self.seconds)
        pos = rng.integers(0, self.n, k)
        amp = np.minimum(rng.pareto(alpha, k) + 1.0, cap) * rng.choice([-1.0, 1.0], k)
        gl, gr = pan_gains(rng.uniform(-spread, spread, k))
        out = self.zeros()
        np.add.at(out[0], pos, amp * gl)
        np.add.at(out[1], pos, amp * gr)
        return out

    def grid(self, count, jitter=0.25, phase=None):
        """`count` event times spread evenly around the circle, with jitter."""
        step = self.seconds / count
        phase = self.rng.uniform(0, step) if phase is None else phase
        return [(phase + (k + self.rng.uniform(-jitter, jitter)) * step) % self.seconds
                for k in range(count)]

    def circ_time(self, onset):
        """Time elapsed since `onset`, measured around the circle (0..L)."""
        return (self.t - onset) % self.seconds


def reverb(cv: Canvas, x, rt60=2.0, wet=0.3, predelay=0.015, damp_hz=5000.0):
    """Circular convolution with a synthetic decaying-noise impulse response."""
    rng = cv.rng
    m = min(cv.n, int(rt60 * 1.3 * SR))
    t = np.arange(m) / SR
    f = np.fft.rfftfreq(m, 1.0 / SR)
    pd = int(predelay * SR)
    hs = []
    for _ in range(2):
        nz = rng.standard_normal(m)
        lo = np.fft.irfft(np.fft.rfft(nz) * lpm(f, damp_hz, 1), n=m)
        ir = lo * np.exp(-6.91 * t / rt60) + (nz - lo) * np.exp(-6.91 * t / (0.35 * rt60))
        ir *= 1.0 - np.exp(-t / 0.005)
        for _ in range(10):  # a few early reflections
            ir[rng.integers(int(0.004 * SR), int(0.07 * SR))] += rng.uniform(-3.0, 3.0)
        ir = np.concatenate([np.zeros(pd), ir])[:m]
        ir /= np.sqrt(np.sum(ir ** 2))
        hs.append(np.fft.rfft(ir, n=cv.n))
    xs = np.fft.rfft(x, axis=-1)
    wl = np.fft.irfft((0.75 * xs[0] + 0.25 * xs[1]) * hs[0], n=cv.n)
    wr = np.fft.irfft((0.25 * xs[0] + 0.75 * xs[1]) * hs[1], n=cv.n)
    return x + wet * np.stack([wl, wr])


# ----------------------------------------------------------------------------
# Loudness, peaks, limiter
# ----------------------------------------------------------------------------

def k_weighting(f):
    """BS.1770 K-weighting (48 kHz coefficients) evaluated on FFT bins."""
    z1 = np.exp(-2j * np.pi * f / SR)
    z2 = z1 * z1
    h1 = (1.53512485958697 - 2.69169618940638 * z1 + 1.19839281085285 * z2) / (
        1.0 - 1.69065929318241 * z1 + 0.73248077421585 * z2)
    h2 = (1.0 - 2.0 * z1 + z2) / (1.0 - 1.99004745483398 * z1 + 0.99007225036621 * z2)
    return h1 * h2


def loudness_lufs(x, circular=True):
    """Integrated loudness (BS.1770-4) of a stereo signal (2, N)."""
    n = x.shape[-1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    y = np.fft.irfft(np.fft.rfft(x, axis=-1) * k_weighting(f), n=n, axis=-1)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    p = y ** 2
    if circular:
        p = np.concatenate([p, p[:, :blk]], axis=1)
        starts = np.arange(0, n, hop)
    else:
        starts = np.arange(0, n - blk + 1, hop)
    cs = np.concatenate([np.zeros((p.shape[0], 1)), np.cumsum(p, axis=1)], axis=1)
    z = (cs[:, starts + blk] - cs[:, starts]) / blk
    s = z.sum(axis=0)
    lj = -0.691 + 10.0 * np.log10(np.maximum(s, 1e-20))
    keep = lj > -70.0
    if not keep.any():
        return float("-inf")
    rel = -0.691 + 10.0 * np.log10(s[keep].mean()) - 10.0
    keep &= lj > rel
    return float(-0.691 + 10.0 * np.log10(s[keep].mean()))


def true_peak(x, oversample=4):
    """Peak of the band-limited (periodic) signal, 4x oversampled via FFT."""
    n = x.shape[-1]
    xs = np.fft.rfft(x, axis=-1)
    ys = np.zeros((x.shape[0], oversample * n // 2 + 1), dtype=complex)
    ys[:, :xs.shape[1]] = xs
    y = np.fft.irfft(ys, n=oversample * n, axis=-1) * oversample
    return float(np.abs(y).max())


def limit(x, ceiling, look=0.002):
    """Circular look-ahead peak limiter: smooth gain never above the needed gain."""
    peak = np.abs(x).max(axis=0)
    g = np.minimum(1.0, ceiling / np.maximum(peak, 1e-12))
    if g.min() >= 1.0:
        return x
    w = int(look * SR)
    width = 2 * w + 1
    m, span = g.copy(), 1
    while span * 2 <= width:  # trailing running minimum by doubling
        m = np.minimum(m, np.roll(m, span))
        span *= 2
    if span < width:
        m = np.minimum(m, np.roll(m, width - span))
    m = np.roll(m, -w)  # centre the window
    kern = np.hanning(width + 2)[1:-1]
    kern /= kern.sum()
    kp = np.zeros(m.size)
    kp[:width] = kern
    kp = np.roll(kp, -w)
    gs = np.fft.irfft(np.fft.rfft(m) * np.fft.rfft(kp), n=m.size)
    return x * np.minimum(gs, 1.0)


def finalize(x):
    """DC/rumble guard, peak normalisation, loudness matching, true-peak safety."""
    x = cfilter(x, [("hp", 22.0, 0.707)])
    x = x - x.mean(axis=1, keepdims=True)
    x = x * (undb(PEAK_NORM_DBFS) / np.abs(x).max())
    x = x * undb(TARGET_LUFS - loudness_lufs(x))
    limited = False
    for _ in range(6):
        if todb(true_peak(x)) <= TRUE_PEAK_MAX_DBTP:
            break
        limited = True
        x = limit(x, undb(TRUE_PEAK_MAX_DBTP - 0.5))
        x = x * undb(TARGET_LUFS - loudness_lufs(x))
    tp = todb(true_peak(x))
    if tp > TRUE_PEAK_MAX_DBTP:  # last resort: accept a slightly lower loudness
        x = x * undb(TRUE_PEAK_MAX_DBTP - tp)
        tp = TRUE_PEAK_MAX_DBTP
    return x, {"lufs": loudness_lufs(x), "true_peak_dbtp": tp, "limited": limited}


# ----------------------------------------------------------------------------
# Shared sound sources
# ----------------------------------------------------------------------------

def bubble(rng, f0, tau, rise):
    """A water bubble: decaying sine whose pitch glides up by `rise` (Minnaert-like)."""
    m = int(tau * 7 * SR) + 8
    t = np.arange(m) / SR
    f = f0 * (1.0 + rise * (1.0 - np.exp(-t / tau)))
    ph = 2.0 * np.pi * np.cumsum(f) / SR + rng.uniform(-0.3, 0.3)
    return np.sin(ph) * np.exp(-t / tau) * (1.0 - np.exp(-t / 0.0015))


def tone(freq, harmonics=((2, 0.08),), phase=0.0):
    """Sine (plus a few harmonics) following an instantaneous-frequency curve."""
    ph = 2.0 * np.pi * np.cumsum(freq) / SR + phase
    out = np.sin(ph)
    for h, a in harmonics:
        out = out + a * np.sin(h * ph)
    return out


def sweep(f_start, f_end, dur, attack=0.008, release=0.015, curve=1.0, vib=None, harm=0.06):
    m = max(8, int(dur * SR))
    x = np.linspace(0.0, 1.0, m) ** curve
    f = f_start * (f_end / f_start) ** x
    if vib:
        rate, depth = vib
        f = f * (1.0 + depth * np.sin(2 * np.pi * rate * np.arange(m) / SR))
    return tone(f, ((2, harm),)) * env_ar(m, attack, release)


def sequence(parts):
    """Mix a list of (offset_seconds, mono_signal) into one array."""
    end = max(int(o * SR) + s.size for o, s in parts)
    out = np.zeros(end)
    for o, s in parts:
        i = int(o * SR)
        out[i:i + s.size] += s
    return out


def wavetable(amps, size=4096, rng=None):
    k = np.arange(size) / size
    w = np.zeros(size)
    for n, a in enumerate(amps, start=1):
        ph = 0.0 if rng is None else rng.uniform(0, 2 * np.pi)
        w += a * np.sin(2 * np.pi * n * k + ph)
    return w / (np.abs(w).max() + 1e-12)


def wt_read(table, freq, phase0=0.0):
    size = table.size
    ph = (phase0 + np.cumsum(freq) / SR) % 1.0
    idx = ph * size
    i0 = idx.astype(np.int64)
    fr = idx - i0
    return table[i0] + fr * (table[(i0 + 1) % size] - table[i0])


# ----------------------------------------------------------------------------
# Nature sounds
# ----------------------------------------------------------------------------

def snd_eau_vive(cv: Canvas):
    f, rng = cv.f, cv.rng
    bed = cv.noise(tilt(f, -3.5) * hpm(f, 70) * lpm(f, 5500) * bump(f, 650, 4.0, 1.5), corr=0.45)
    bed *= cv.drift(7.0, 0.6, 1.25) * cv.drift(0.25, 0.85, 1.1)
    spray = cv.noise(tilt(f, -2.0) * hpm(f, 1800) * lpm(f, 9000), corr=0.3) * cv.drift(12.0, 0.3, 1.0)
    low = cv.noise(tilt(f, -6.0) * hpm(f, 35) * lpm(f, 220), corr=0.6) * cv.drift(1.5, 0.7, 1.2)
    bubbles = cv.zeros()
    for t0 in rng.uniform(0, cv.seconds, int(26 * cv.seconds)):
        f0 = loguniform(rng, 280, 1500)
        tau = 0.012 * (500 / f0) ** 0.8 * rng.uniform(0.6, 1.4)
        cv.place(bubbles, t0, bubble(rng, f0, tau, rng.uniform(0.1, 0.5)) * rng.lognormal(0, 0.5),
                 pan=rng.uniform(-0.8, 0.8))
    x = bed + undb(-14) * spray + undb(-8) * low + undb(-12) * unit_rms(bubbles)
    return reverb(cv, x, rt60=0.9, wet=0.12, damp_hz=4000)


def snd_ruisseau(cv: Canvas):
    f, rng = cv.f, cv.rng
    bed = cv.noise(tilt(f, -2.5) * hpm(f, 250) * lpm(f, 6500) * bump(f, 1400, 5.0, 1.2), corr=0.4)
    bed *= cv.drift(4.0, 0.55, 1.2)
    gurgle = cv.noise(tilt(f, -4.0) * hpm(f, 90) * lpm(f, 450), corr=0.5) * cv.drift(2.5, 0.15, 1.0) ** 2
    bubbles = cv.zeros()
    for tc in rng.uniform(0, cv.seconds, rng.poisson(5.5 * cv.seconds)):
        fc, pan, t0 = loguniform(rng, 450, 2600), rng.uniform(-0.85, 0.85), tc
        for _ in range(1 + rng.poisson(2.5)):
            f0 = fc * 2.0 ** rng.normal(0, 0.12)
            tau = 0.016 * (700 / f0) ** 0.7 * rng.uniform(0.6, 1.5)
            cv.place(bubbles, t0, bubble(rng, f0, tau, rng.uniform(0.3, 1.0)) * rng.lognormal(0, 0.45),
                     pan=float(np.clip(pan + rng.normal(0, 0.08), -1, 1)))
            t0 += rng.uniform(0.012, 0.06)
    x = unit_rms(bubbles) + undb(-7) * bed + undb(-12) * gurgle
    return reverb(cv, x, rt60=0.6, wet=0.15, damp_hz=5000)


def snd_pluie_douce(cv: Canvas):
    f, rng = cv.f, cv.rng
    bed = cv.noise(tilt(f, -1.5) * hpm(f, 350) * lpm(f, 8500) * bump(f, 3200, 3.0, 1.5), corr=0.2)
    bed *= cv.drift(0.2, 0.88, 1.08)
    drops = cv.zeros()
    for rate, fc, q in ((500, 1900, 2.5), (700, 3000, 3.0), (600, 4500, 3.0), (300, 6500, 2.0)):
        drops += unit_rms(cfilter(cv.impulses(rate, alpha=2.2, cap=6.0), [("bp", fc, q)]))
    near = cfilter(cv.impulses(6, alpha=2.5, cap=2.5), [("bp", 1300, 1.4), ("lp", 4000, 0.7)])
    plinks = cv.zeros()
    for t0 in rng.uniform(0, cv.seconds, rng.poisson(1.2 * cv.seconds)):
        cv.place(plinks, t0, bubble(rng, loguniform(rng, 1200, 2800), rng.uniform(0.006, 0.014),
                                    rng.uniform(0.3, 0.8)), pan=rng.uniform(-0.9, 0.9))
    x = bed + undb(-5) * unit_rms(drops) + undb(-17) * unit_rms(near) + undb(-21) * unit_rms(plinks)
    return reverb(cv, x, rt60=0.5, wet=0.1, damp_hz=6000)


def snd_vent(cv: Canvas):
    f = cv.f
    g = cv.drift(0.09, 0.12, 1.0)
    g = np.clip(g + 0.12 * (cv.drift(0.7) - 0.5), 0.06, 1.1)
    base = cv.noise(tilt(f, -5.0) * hpm(f, 30) * lpm(f, 1000, 1), corr=0.25) * g ** 1.3
    mid = cv.noise(tilt(f, -3.0) * hpm(f, 350) * lpm(f, 2800), corr=0.25) * g ** 2.2
    howl = cv.zeros()
    for fc, shift in ((430, 0.0), (610, 0.12), (880, -0.08)):
        band = cv.noise(np.abs(biquad(f, "bp", fc, 14.0)), corr=0.5)
        env = np.clip((g - 0.45 + shift) / 0.55, 0.0, None) ** 2 * cv.drift(0.35, 0.3, 1.0)
        howl += band * env
    leaves = cv.noise(tilt(f, -2.0) * hpm(f, 2500) * lpm(f, 9000), corr=0.2) * g ** 2 * cv.drift(10.0, 0.4, 1.0)
    return base + undb(-6) * mid + undb(-17) * howl + undb(-21) * leaves


def snd_vagues(cv: Canvas):
    f, rng = cv.f, cv.rng
    spacing = [7.6, 9.2, 8.1, 9.6, 8.5]  # five waves per loop
    assert abs(sum(spacing) - cv.seconds) < 1e-9
    onsets = 0.8 + np.concatenate([[0.0], np.cumsum(spacing[:-1])])
    low = cv.noise(tilt(f, -6.0) * hpm(f, 30) * lpm(f, 450), corr=0.55)
    mid = cv.noise(tilt(f, -3.0) * hpm(f, 180) * lpm(f, 3500), corr=0.45)
    hi = cv.noise(tilt(f, -1.0) * hpm(f, 2200) * lpm(f, 10000), corr=0.3)
    e_low, e_mid, e_hi = cv.zeros(), cv.zeros(), cv.zeros()
    for o in onsets:
        tau = cv.circ_time(o)
        rise, a, bal = rng.uniform(2.4, 3.4), rng.uniform(0.7, 1.0), rng.uniform(-0.35, 0.35)
        bright = rng.uniform(0.7, 1.0)
        swell = np.where(tau < rise, 0.5 - 0.5 * np.cos(np.pi * tau / rise), np.exp(-(tau - rise) / 2.6))
        ct = tau - (rise - 0.35)
        crash = np.where(ct < 0, 0.0, np.where(ct < 0.45, (np.maximum(ct, 0) / 0.45) ** 1.5,
                                               np.exp(-(ct - 0.45) / 1.5)))
        ft = np.maximum(tau - rise, 0.0)
        foam = (1.0 - np.exp(-ft / 0.6)) * np.exp(-ft / 3.2)
        ch = np.array([[1.0 - bal], [1.0 + bal]])
        e_low += a * swell * ch
        e_mid += a * bright * crash * ch
        e_hi += a * foam * ch
    murmur = cv.noise(tilt(f, -5.0) * hpm(f, 40) * lpm(f, 600), corr=0.4) * cv.drift(0.2, 0.6, 1.0)
    pebbles = cfilter(cv.impulses(45, alpha=2.0, cap=5.0), [("bp", 3500, 1.2)])
    pebbles = unit_rms(pebbles) * e_hi
    x = low * e_low + 0.55 * mid * e_mid + 0.3 * hi * e_hi + 0.18 * murmur + undb(-24) * pebbles
    return reverb(cv, x, rt60=1.2, wet=0.1, damp_hz=4000)


def snd_feu_de_camp(cv: Canvas):
    f, rng = cv.f, cv.rng
    roar = cv.noise(tilt(f, -6.0) * hpm(f, 40) * lpm(f, 320), corr=0.6) * cv.drift(1.2, 0.5, 1.3)
    flame = cv.noise(tilt(f, -3.0) * hpm(f, 250) * lpm(f, 1400) * bump(f, 600, 3.0, 1.0), corr=0.5)
    flame *= cv.drift(2.0, 0.4, 1.2)
    hiss = cv.noise(tilt(f, -3.0) * hpm(f, 1500) * lpm(f, 7000), corr=0.4) * cv.drift(3.0, 0.3, 1.0)
    crack = cv.zeros()
    for tc in rng.uniform(0, cv.seconds, rng.poisson(3.2 * cv.seconds)):
        pan = rng.uniform(-0.7, 0.7)
        base = min(rng.pareto(1.8) + 1.0, 6.0)
        for _ in range(1 + rng.poisson(3.0)):
            ln = int(rng.uniform(0.0002, 0.0015) * SR) + 4
            burst = rng.standard_normal(ln) * np.exp(-np.arange(ln) / (ln * 0.3))
            cv.place(crack, tc + rng.uniform(0, 0.12), burst * base * rng.uniform(0.3, 1.0),
                     pan=float(np.clip(pan + rng.normal(0, 0.1), -1, 1)))
    crack = cfilter(crack, [("hp", 900, 0.7), ("peak", 3500, 1.0, 4.0), ("lp", 9000, 0.7)])
    pops = cv.zeros()
    for t0 in rng.uniform(0, cv.seconds, rng.poisson(0.4 * cv.seconds)):
        ln = int(0.004 * SR)
        burst = rng.standard_normal(ln) * np.exp(-np.arange(ln) / (ln * 0.4))
        pop = efilter(burst, [("bp", rng.uniform(600, 1500), 2.5)], tail=0.04)
        cv.place(pops, t0, pop * rng.uniform(0.5, 1.0), pan=rng.uniform(-0.6, 0.6))
    whistle = cv.zeros()
    for t0 in (7.3, 19.1):
        m = int(rng.uniform(0.7, 1.3) * SR)
        jit = emag(rng.standard_normal(m), lambda fr: lpm(fr, 12.0, 2))
        fw = rng.uniform(1900, 2500) * (1.0 + 0.01 * jit / (np.abs(jit).max() + 1e-12))
        cv.place(whistle, t0, tone(fw, ()) * env_ar(m, 0.25, 0.35), pan=rng.uniform(-0.3, 0.3))

    def pk(v):
        return float(np.percentile(np.abs(v), 99.99)) + 1e-12

    x = (roar + undb(-9) * flame + undb(-15) * hiss + 3.0 * crack / pk(crack) + 2.2 * pops / pk(pops)
         + undb(-30) * unit_rms(whistle) * 3.0)
    return reverb(cv, x, rt60=0.7, wet=0.08, damp_hz=5000)


def cricket_chirp(fc, pulses, pulse_len, pulse_period, rng):
    parts = []
    for p in range(pulses):
        m = int(pulse_len * SR)
        tt = np.arange(m) / m
        fp = fc * (1.0 - 0.012 * tt)
        env = np.sin(np.pi * tt ** 0.7) ** 2
        parts.append((p * pulse_period, tone(fp, ((2, 0.06),)) * env * rng.uniform(0.8, 1.0)))
    return sequence(parts)


def snd_grillons(cv: Canvas):
    f, rng = cv.f, cv.rng
    crickets = cv.zeros()
    # carrier, pulses, pulse length, pulse period, chirp period, pan, level dB, rest window
    specs = ((4550, 3, 0.014, 0.028, 0.64, -0.45, 0.0, None),
             (4200, 4, 0.012, 0.024, 0.83, 0.50, -4.0, (8.0, 12.5)),
             (4800, 3, 0.016, 0.030, 0.55, 0.15, -9.0, (15.0, 19.0)),
             (3900, 2, 0.018, 0.032, 0.95, -0.80, -12.0, None))
    for fc, pulses, pl, pp, period, pan, lvl, rest in specs:
        count = max(1, round(cv.seconds / period))  # integer number of chirps per loop
        step = cv.seconds / count
        phase = rng.uniform(0, step)
        for k in range(count):
            t0 = phase + k * step + rng.normal(0, 0.004)
            g = undb(lvl + rng.normal(0, 0.7))
            if rest is not None:
                tm = t0 % cv.seconds
                dist = min(abs(tm - rest[0]), abs(tm - rest[1]))
                if rest[0] <= tm <= rest[1]:
                    continue
                g *= min(1.0, 0.35 + dist / 2.0)
            chirp = cricket_chirp(fc * (1 + rng.normal(0, 0.002)), pulses, pl, pp, rng)
            if lvl < -8:
                chirp = efilter(chirp, [("lp", 3500, 0.7)], tail=0.01)
            cv.place(crickets, t0, chirp * g, pan=pan)
    crickets = cfilter(crickets, [("lp", 7000, 0.7)])
    am = (0.5 + 0.5 * cv.lfo(cv.cycles(21.0))) ** 6 * cv.drift(0.3, 0.3, 1.0)
    chorus = cv.noise(np.abs(biquad(f, "bp", 4400, 4.0)), corr=0.2) * am
    night = cv.noise(tilt(f, -5.0) * hpm(f, 40) * lpm(f, 700), corr=0.3) * cv.drift(0.1, 0.6, 1.0)
    x = unit_rms(crickets) + undb(-17) * chorus + undb(-11) * night
    return reverb(cv, x, rt60=0.8, wet=0.18, damp_hz=6000)


def owl_note(rng, f0, dur, tremolo=None, gain=1.0):
    m = int(dur * SR)
    t = np.arange(m) / SR
    contour = f0 * (1.0 + 0.06 * (1.0 - np.exp(-t / 0.05)) - 0.08 * (t / dur) ** 2)
    contour *= 1.0 + 0.004 * np.sin(2 * np.pi * 5.0 * t)
    sig = tone(contour, ((2, 0.16), (3, 0.04)), phase=rng.uniform(0, 2 * np.pi))
    env = env_ar(m, min(0.09, dur * 0.3), min(0.14, dur * 0.4)) * (1.0 - 0.15 * t / dur)
    if tremolo:
        rate, depth = tremolo
        env *= 1.0 - depth * (0.5 + 0.5 * np.cos(2 * np.pi * rate * t)) * np.clip(1.4 - 1.6 * t / dur, 0, 1)
    breath = efilter(rng.standard_normal(m), [("bp", f0 * 1.05, 4.0), ("bp", f0 * 1.05, 4.0),
                                              ("lp", 1500, 0.7)], tail=0.0)[:m]
    return (sig + 0.08 * unit_rms(breath)) * env * gain


def owl_call(rng, f0, gain=1.0):
    return sequence([
        (0.0, owl_note(rng, f0, 0.9, gain=gain)),
        (0.9 + rng.uniform(2.8, 3.6), owl_note(rng, f0 * 0.97, 0.2, gain=gain * 0.7)),
        (0.9 + 3.2 + 0.55, owl_note(rng, f0 * 1.03, 1.7, tremolo=(9.0, 0.75), gain=gain)),
    ])


def snd_chouette(cv: Canvas):
    f, rng = cv.f, cv.rng
    owls = cv.zeros()
    for t0, f0, pan, gain, far in ((4.0, 430.0, -0.35, 1.0, False), (17.5, 395.0, 0.6, 0.45, True),
                                   (24.0, 425.0, -0.3, 0.9, False), (34.8, 400.0, 0.55, 0.4, True)):
        call = owl_call(rng, f0, gain)
        if far:
            call = efilter(call, [("lp", 1200, 0.7)], tail=0.05)
        cv.place(owls, t0, call, pan=pan)
    gust = cv.drift(0.08, 0.4, 1.0)
    bed = cv.noise(tilt(f, -5.0) * hpm(f, 40) * lpm(f, 900), corr=0.3) * gust
    leaves = cv.noise(tilt(f, -2.0) * hpm(f, 2000) * lpm(f, 7000), corr=0.2) * gust ** 2
    x = unit_rms(owls) + undb(-12) * bed + undb(-24) * leaves
    return reverb(cv, x, rt60=1.8, wet=0.4, damp_hz=3000)


# --- birds ---------------------------------------------------------------------

def bird_tit(rng):
    s = rng.uniform(0.97, 1.03)
    parts, t = [], 0.0
    for _ in range(rng.integers(3, 5)):
        parts.append((t, sweep(5300 * s, 5000 * s, 0.09)))
        parts.append((t + 0.12, sweep(3700 * s, 3400 * s, 0.11)))
        t += 0.12 + 0.11 + rng.uniform(0.1, 0.14)
    return sequence(parts)


def bird_warbler(rng):
    parts, t = [], 0.0
    for _ in range(rng.integers(7, 13)):
        kind = rng.integers(0, 4)
        if kind == 0:
            d = rng.uniform(0.06, 0.12)
            sig = sweep(rng.uniform(2400, 2900), rng.uniform(3800, 4400), d)
        elif kind == 1:
            d = rng.uniform(0.05, 0.1)
            sig = sweep(rng.uniform(4400, 5000), rng.uniform(2900, 3300), d)
        elif kind == 2:
            d = rng.uniform(0.2, 0.35)
            m = int(d * SR)
            am = 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(24, 32) * np.arange(m) / SR)
            sig = sweep(rng.uniform(3300, 3800), rng.uniform(3000, 3400), d) * am
        else:
            d = 0.025
            sig = sweep(6000, 5000, d, attack=0.003, release=0.008)
        parts.append((t, sig * rng.uniform(0.6, 1.0)))
        t += d + rng.uniform(0.02, 0.07)
    return sequence(parts)


def bird_blackbird(rng):
    parts, t = [], 0.0
    for _ in range(rng.integers(3, 6)):
        d = rng.uniform(0.12, 0.3)
        m = int(d * SR)
        x = np.linspace(0, 1, m)
        f0 = rng.uniform(1900, 2800)
        fr = f0 * (1.0 + rng.uniform(0.08, 0.18) * np.sin(np.pi * x)) * (
            1.0 + 0.012 * np.sin(2 * np.pi * rng.uniform(25, 35) * np.arange(m) / SR))
        parts.append((t, tone(fr, ((2, 0.12),)) * env_ar(m, 0.025, 0.04) * rng.uniform(0.7, 1.0)))
        t += d + rng.uniform(0.05, 0.12)
    for _ in range(3):  # quiet twittery ending
        parts.append((t, 0.35 * sweep(rng.uniform(4200, 5000), rng.uniform(3800, 4400), 0.04)))
        t += 0.06
    return sequence(parts)


def bird_tsip(rng):
    parts, t = [], 0.0
    for _ in range(rng.integers(2, 6)):
        parts.append((t, sweep(6200, 4300, 0.035, attack=0.004, release=0.01)))
        t += rng.uniform(0.12, 0.3)
    return sequence(parts)


def bird_finch(rng):
    """Accelerating, descending trill ending with a flourish."""
    parts, t, f0 = [], 0.0, rng.uniform(4600, 5200)
    gap = 0.11
    for i in range(rng.integers(8, 13)):
        parts.append((t, sweep(f0, f0 * 0.85, 0.045, attack=0.004, release=0.012) * (0.6 + 0.04 * i)))
        f0 *= 0.975
        t += gap
        gap = max(0.055, gap * 0.92)
    parts.append((t + 0.03, sweep(f0 * 0.9, f0 * 1.35, 0.16, curve=0.6)))
    return sequence(parts)


def snd_oiseaux(cv: Canvas):
    f, rng = cv.f, cv.rng
    birds = cv.zeros()
    for fn, count, pans, gain, lp in ((bird_warbler, 7, (-0.45,), 1.0, None),
                                      (bird_tit, 5, (0.55,), 0.8, None),
                                      (bird_blackbird, 4, (0.1,), 0.75, 6000),
                                      (bird_finch, 4, (0.75, -0.65), 0.55, 5000),
                                      (bird_tsip, 12, (-0.85, 0.8), 0.35, 4500)):
        for i, t0 in enumerate(cv.grid(count, jitter=0.3)):
            song = fn(rng)
            if lp:
                song = efilter(song, [("lp", lp, 0.7)], tail=0.02)
            cv.place(birds, t0, song * gain, pan=pans[i % len(pans)] + rng.normal(0, 0.05))
    birds = cfilter(birds, [("highshelf", 7000, 0.707, -3.0)])
    birds = birds / (np.percentile(np.abs(birds), 99.9) + 1e-12)
    bed = cv.noise(tilt(f, -3.0) * hpm(f, 150) * lpm(f, 4000), corr=0.3) * cv.drift(0.15, 0.5, 1.0)
    x = birds + 0.06 * bed
    return reverb(cv, x, rt60=1.3, wet=0.25, damp_hz=4000)


# ----------------------------------------------------------------------------
# Instruments (one-shot notes; placed circularly so tails wrap around)
# ----------------------------------------------------------------------------

def piano_note(rng, f0, hold, vel):
    m = int((hold + 0.7) * SR)
    t = np.arange(m) / SR
    tau0 = float(np.clip(4.5 * (130.0 / f0) ** 0.55, 0.7, 7.0))
    inharm = 1.5e-4 * np.sqrt(f0 / 130.0)
    out = np.zeros(m)
    for n in range(1, max(1, min(12, int(6500 / f0))) + 1):
        fn = n * f0 * np.sqrt(1.0 + inharm * n * n)
        a = n ** -1.3 * np.exp(-(n - 1) * (0.55 - 0.3 * vel))
        tau = tau0 / (1.0 + 0.45 * (n - 1))
        env = 0.55 * np.exp(-t / (0.25 * tau)) + 0.45 * np.exp(-t / tau)
        det = 2.0 ** (rng.uniform(0.3, 1.2) / 1200.0)
        out += a * env * 0.5 * (np.sin(2 * np.pi * fn * t + rng.uniform(0, 6.3))
                                + np.sin(2 * np.pi * fn * det * t + rng.uniform(0, 6.3)))
    out *= 1.0 - np.exp(-t / 0.0025)
    out *= np.where(t > hold, np.exp(-(t - hold) / 0.15), 1.0)
    k = int(0.006 * SR)
    out[:k] += 0.015 * vel * np.convolve(rng.standard_normal(k), np.ones(8) / 8, "same") * np.hanning(k)
    return out * vel


def harp_note(rng, f0, vel):
    tau1 = float(np.clip(2.2 * (196.0 / f0) ** 0.5, 0.6, 3.5))
    m = int(min(7.0, tau1 * 5.5) * SR)
    t = np.arange(m) / SR
    out = np.zeros(m)
    for n in range(1, max(1, min(10, int(7000 / f0))) + 1):
        a = abs(np.sin(np.pi * n * 0.13)) / n ** 1.5
        out += a * np.exp(-t / (tau1 / n ** 0.8)) * np.sin(2 * np.pi * n * f0 * t + rng.uniform(0, 6.3))
    out *= 1.0 - np.exp(-t / 0.002)
    out *= env_ar(m, 0.0, 0.3)
    return out * vel


def flute_note(rng, f0, dur, vel):
    m = int((dur + 0.25) * SR)
    t = np.arange(m) / SR
    env = env_ar(m, 0.11, 0.25) * (0.9 + 0.1 * np.sin(np.pi * np.minimum(t / dur, 1.0)))
    vib = 1.0 + 0.006 * np.clip((t - 0.35) / 0.5, 0, 1) * np.sin(2 * np.pi * 5.0 * t + rng.uniform(0, 6.3))
    sig = tone(f0 * vib, ((2, 0.22), (3, 0.07), (4, 0.025)))
    breath = unit_rms(efilter(rng.standard_normal(m), [("bp", f0 * 2.0, 1.2)], tail=0.0)[:m])
    air = unit_rms(efilter(rng.standard_normal(m), [("hp", 1500, 0.7), ("lp", 6000, 0.7)], tail=0.0)[:m])
    chiff = np.exp(-t / 0.03)
    return (sig * env + (0.05 * breath + 0.025 * air) * env + 0.06 * air * chiff) * vel


def soft_pad_note(rng, f0, dur, vel, attack=1.2, release=1.5):
    """Dark sine-ish pad voice (two detuned wavetable oscillators)."""
    m = int(dur * SR)
    table = wavetable([1.0, 0.25, 0.08, 0.03], rng=rng)
    out = np.zeros(m)
    for cents in (-4.0, 4.0):
        out += wt_read(table, np.full(m, f0 * 2.0 ** (cents / 1200.0)), rng.uniform())
    return 0.5 * out * env_ar(m, attack, release) * vel


def string_note(rng, f0, dur, vel, attack=1.8, release=2.4):
    """Slow bowed-string ensemble voice: three detuned band-limited saws, stereo."""
    m = int(dur * SR)
    t = np.arange(m) / SR
    nmax = max(1, min(40, int(7000 / f0)))
    amps = [(1.0 / n) * lpm(n * f0, 1700.0, 2) * bump(n * f0, 450.0, 3.0, 1.5) for n in range(1, nmax + 1)]
    table = wavetable(amps, rng=rng)
    vib_on = np.clip((t - 0.4) / 1.2, 0, 1)
    out = np.zeros((2, m))
    for cents, pan in ((-7.0, -0.5), (0.0, 0.0), (6.0, 0.5)):
        fr = f0 * 2.0 ** (cents / 1200.0) * (1.0 + 0.0025 * vib_on * np.sin(
            2 * np.pi * rng.uniform(4.6, 5.6) * t + rng.uniform(0, 6.3)))
        v = wt_read(table, fr, rng.uniform())
        gl, gr = pan_gains(pan)
        out[0] += gl * v
        out[1] += gr * v
    swell = 0.85 + 0.15 * np.sin(np.pi * t / (dur + 1e-9))
    return out * env_ar(m, attack, release) * swell * vel / 3.0


def ks_pluck(rng, f0, dur, vel, t60=3.0, bright=0.5):
    """Karplus-Strong string with a fractional-delay loop filter (vectorised by periods)."""
    m = int(dur * SR)
    pf = SR / f0 - 0.5
    p = int(np.floor(pf))
    d = pf - p
    c0, c1, c2 = 0.5 * (1 - d), 0.5, 0.5 * d
    g = 10.0 ** (-3.0 / (t60 * f0))
    ex = rng.uniform(-1.0, 1.0, p)
    k = max(1, int(round(2 + 10 * (1.0 - bright))))
    ex = np.convolve(ex, np.ones(k) / k, mode="same")
    beta = max(1, int(p * 0.18))
    ex = ex - 0.6 * np.concatenate([np.zeros(beta), ex[:-beta]])
    ex -= ex.mean()
    o = p + 2
    y = np.zeros(m + o)
    y[o:o + p] = ex
    s = p
    while s < m:
        e = min(s + p, m)
        a, b = s + o, e + o
        y[a:b] = g * (c0 * y[a - p:b - p] + c1 * y[a - p - 1:b - p - 1] + c2 * y[a - p - 2:b - p - 2])
        s = e
    out = y[o:o + m]
    out = out / (np.abs(out).max() + 1e-12)
    return out * env_ar(m, 0.0005, 0.3) * vel


def musicbox_note(rng, f0, vel):
    m = int(3.2 * SR)
    t = np.arange(m) / SR
    f0 = f0 * 2.0 ** (rng.normal(0, 2.5) / 1200.0)
    tau1 = float(np.clip(1.6 * (800.0 / f0) ** 0.7, 0.5, 2.5))
    out = np.sin(2 * np.pi * f0 * t) * np.exp(-t / tau1)
    out += 0.12 * np.sin(2 * np.pi * 2.0008 * f0 * t + 0.4) * np.exp(-t / (0.4 * tau1))
    out += 0.04 * np.sin(2 * np.pi * 3.0 * f0 * t + 1.1) * np.exp(-t / (0.2 * tau1))
    if 5.4 * f0 < 11000:
        out += 0.05 * np.sin(2 * np.pi * 5.4 * f0 * t) * np.exp(-t / 0.05)
    out *= 1.0 - np.exp(-t / 0.0007)
    k = int(0.0015 * SR)
    out[:k] += 0.03 * rng.standard_normal(k) * np.hanning(k)
    return out * env_ar(m, 0.0, 0.4) * vel


BOWLS = (  # fundamental, inharmonic mode ratios, amplitudes, decay (s), doublet split (Hz)
    (hz("F3"), (1.0, 2.71, 5.12, 8.21), (1.0, 0.55, 0.25, 0.1), (11.0, 6.0, 3.0, 1.6), (0.9, 1.6, 2.4, 3.1)),
    (hz("Bb3"), (1.0, 2.68, 5.05, 8.10), (1.0, 0.5, 0.22, 0.09), (9.5, 5.0, 2.6, 1.4), (1.1, 1.9, 2.2, 3.4)),
    (hz("Eb4"), (1.0, 2.74, 5.20, 8.30), (1.0, 0.45, 0.2, 0.08), (8.0, 4.2, 2.2, 1.2), (1.3, 2.1, 2.8, 3.6)),
)


def bowl_strike(rng, bowl, vel):
    f0, ratios, amps, taus, splits = bowl
    m = int(6.5 * max(taus) * SR)
    t = np.arange(m) / SR
    out = np.zeros(m)
    for r, a, tau, dlt in zip(ratios, amps, taus, splits):
        fr = f0 * r
        out += a * np.exp(-t / tau) * 0.5 * (np.sin(2 * np.pi * fr * t + rng.uniform(0, 6.3))
                                             + np.sin(2 * np.pi * (fr + dlt) * t + rng.uniform(0, 6.3)))
    out *= 1.0 - np.exp(-t / 0.004)
    k = int(0.02 * SR)
    out[:k] += 0.05 * efilter(rng.standard_normal(k), [("lp", 700, 0.7)], tail=0.0)[:k] * np.hanning(k)
    return out * vel


# ----------------------------------------------------------------------------
# Music beds
# ----------------------------------------------------------------------------

def check_meter(cv, beats, beat):
    if abs(cv.seconds - beats * beat) > 1e-6:
        raise ValueError(f"loop {cv.seconds}s is not {beats} beats of {beat}s")


def mus_piano_doux(cv: Canvas):
    rng, beat = cv.rng, 1.1
    check_meter(cv, 32, beat)
    x = cv.zeros()
    chords = (("F2", "C3", "A3", "E4"), ("D2", "A2", "F3", "E4"), ("Bb1", "F2", "D3", "A3"),
              ("C2", "G2", "F3", "Bb3"))
    last_bar = ("C2", "G2", "E3", "Bb3")
    for c, voicing in enumerate(chords):
        start = c * 8 * beat
        end = start + 8 * beat
        for bar in range(2):
            v = last_bar if (c == 3 and bar == 1) else voicing
            pattern = ((0, 0), (1, 1), (2, 2), (4, 3), (5, 2), (6, 1)) if bar == 0 else \
                ((0, 0), (2, 2), (3, 3), (5, 1), (6, 2))
            for eighth, idx in pattern:
                t0 = start + bar * 4 * beat + eighth * beat / 2 + rng.normal(0, 0.008)
                vel = 0.42 if idx == 0 else rng.uniform(0.26, 0.34)
                note = piano_note(rng, hz(v[idx]), end - t0 + 0.1, vel)
                cv.place(x, t0, note, pan=-0.25 + 0.12 * idx)
    melody = ((0, 2, "C5"), (2, 1, "A4"), (3, 1, "G4"), (4, 3, "A4"), (7, 1, "C5"),
              (8, 2, "F5"), (10, 1, "E5"), (11, 1, "D5"), (12, 2, "E5"), (14, 2, "A4"),
              (16, 2, "D5"), (18, 1, "C5"), (19, 1, "Bb4"), (20, 2, "A4"), (22, 1, "F4"), (23, 1, "G4"),
              (24, 2, "G4"), (26, 1, "C5"), (27, 1, "Bb4"), (28, 2, "A4"), (30, 2, "G4"))
    for b, ln, name in melody:
        t0 = b * beat + rng.normal(0, 0.01)
        cv.place(x, t0, piano_note(rng, hz(name), ln * beat * 1.05, rng.uniform(0.42, 0.5)), pan=0.2)
    x = cfilter(x, [("lp", 3200, 0.6), ("highshelf", 5000, 0.707, -3.0)])
    return reverb(cv, x, rt60=2.4, wet=0.32, damp_hz=3500)


def mus_harpe(cv: Canvas):
    rng, e8 = cv.rng, 0.42
    check_meter(cv, 96, e8)
    x = cv.zeros()
    voicings = (
        ("D2", "A2", "D3", "F#3", "A3", "D4", "E4", "F#4", "A4"),
        ("B1", "F#2", "B2", "D3", "F#3", "B3", "C#4", "D4", "F#4"),
        ("G2", "D3", "G3", "B3", "D4", "G4", "A4", "B4", "D5"),
        ("A2", "E3", "A3", "C#4", "E4", "A4", "B4", "C#5", "E5"),
        ("F#2", "A2", "D3", "F#3", "A3", "D4", "E4", "F#4", "A4"),
        ("G2", "D3", "G3", "B3", "D4", "G4", "A4", "B4", "D5"),
        ("E2", "B2", "E3", "G3", "B3", "E4", "F#4", "G4", "B4"),
        ("A2", "E3", "A3", "D4", "E4", "A4", "B4", "D5", "E5"),
    )
    resolve = ("A2", "E3", "A3", "C#4", "E4", "A4", "B4", "C#5", "E5")
    patterns = ((0, 1, 2, 3, 4, 5, 6, 7, 8, 6, 5, 3), (0, 2, 3, 4, 5, 7, 8, 7, 6, 4, 3, 1))
    for c, v in enumerate(voicings):
        for i, idx in enumerate(patterns[c % 2]):
            voicing = resolve if (c == 7 and i >= 6) else v
            t0 = (c * 12 + i) * e8 + rng.normal(0, 0.008)
            vel = 0.55 if i == 0 else (0.45 if i in (6, 8) or idx == 8 else rng.uniform(0.3, 0.4))
            cv.place(x, t0, harp_note(rng, hz(voicing[idx]), vel), pan=-0.5 + idx / 8.0)
    x = cfilter(x, [("lp", 6000, 0.7)])
    return reverb(cv, x, rt60=2.8, wet=0.38, damp_hz=4000)


def mus_flute(cv: Canvas):
    rng, beat = cv.rng, 1.15
    check_meter(cv, 32, beat)
    x = cv.zeros()
    melody = (("B4", 2), ("A4", 1), ("G4", 1), ("E4", 3), (None, 1), ("G4", 1), ("A4", 1), ("B4", 2),
              ("D5", 2), ("B4", 2), ("A4", 2), ("G4", 1), ("E4", 1), ("D4", 2), ("E4", 2),
              ("G4", 1.5), ("A4", 0.5), ("G4", 1), ("E4", 1), ("E4", 3), (None, 1))
    b = 0.0
    for name, ln in melody:
        if name:
            t0 = b * beat + rng.normal(0, 0.01)
            cv.place(x, t0, flute_note(rng, hz(name), ln * beat - 0.05, rng.uniform(0.85, 1.0)), pan=0.1)
        b += ln
    assert abs(b - 32) < 1e-9
    pad = cv.zeros()
    chords = (("E2", "B2", "G3"), ("C2", "G2", "E3"), ("G2", "D3", "B3"), ("B1", "F#2", "D3"),
              ("A2", "E3", "C4"), ("E2", "B2", "G3"), ("C2", "G2", "E3"), ("D2", "A2", "F#3"))
    for i, ch in enumerate(chords):
        for k, name in enumerate(ch):
            note = soft_pad_note(rng, hz(name), 4 * beat + 1.1, 0.8 if k == 0 else 0.6)
            cv.place(pad, i * 4 * beat - 0.3, note, pan=(-0.4, 0.4, 0.0)[k])
    x = unit_rms(x) + undb(-11) * unit_rms(pad)
    return reverb(cv, x, rt60=3.0, wet=0.4, damp_hz=4500)


def mus_guitare_douce(cv: Canvas):
    rng, beat = cv.rng, 0.9
    check_meter(cv, 32, beat)
    x = cv.zeros()
    chords = (  # bass, alternate bass, upper strings (low to high)
        ("G2", "D3", ("G3", "B3", "D4", "F#4")),
        ("E2", "B2", ("G3", "B3", "D4", "E4")),
        ("C3", "G2", ("E3", "G3", "B3", "E4")),
        ("D3", "A2", ("A3", "D4", "G4", "D4")),
    )
    resolved = ("D3", "A2", ("A3", "D4", "F#4", "D4"))
    pattern = ("b", 0, 2, 1, "a", 0, 3, 1)
    for c, chord in enumerate(chords):
        for bar in range(2):
            bass, alt, up = resolved if (c == 3 and bar == 1) else chord
            for i, step in enumerate(pattern):
                t0 = ((c * 2 + bar) * 8 + i) * beat / 2 + rng.normal(0, 0.008)
                if step == "b":
                    name, vel, pan, t60 = bass, 0.62, -0.3, 3.5
                elif step == "a":
                    name, vel, pan, t60 = alt, 0.5, -0.3, 3.0
                else:
                    name, vel, pan, t60 = up[step], rng.uniform(0.32, 0.42), -0.1 + 0.15 * step, 2.6
                cv.place(x, t0, ks_pluck(rng, hz(name), 3.6, vel, t60=t60, bright=0.35), pan=pan)
    x = cfilter(x, [("hp", 70, 0.7), ("peak", 120, 1.0, 3.0), ("peak", 250, 1.0, 2.0), ("lp", 5000, 0.7)])
    return reverb(cv, x, rt60=1.6, wet=0.22, damp_hz=4000)


def mus_cordes_lentes(cv: Canvas):
    rng, beat = cv.rng, 1.4
    check_meter(cv, 32, beat)
    x = cv.zeros()
    chord_len = 8 * beat
    chords = (("D2", "F3", "A3", "D4", "A4"), ("Bb1", "F3", "A3", "D4", "F4"),
              ("G2", "F3", "Bb3", "D4", "G4"), ("A2", "E3", "A3", "C#4", "E4"))
    pans = (-0.25, -0.1, 0.1, 0.25, 0.0)
    for c, ch in enumerate(chords):
        for k, name in enumerate(ch):
            f0 = hz(name)
            if c == 3 and k == 3:  # A7sus4 -> A: D4 resolves to C#4 halfway
                for j, nm in enumerate(("D4", "C#4")):
                    note = string_note(rng, hz(nm), chord_len / 2 + 2.0, 0.55, attack=1.2, release=1.6)
                    cv.place(x, c * chord_len + j * chord_len / 2 - 0.4, note, pan=pans[k])
                continue
            vel = 0.75 if k == 0 else 0.55
            note = string_note(rng, f0, chord_len + 1.6, vel)
            cv.place(x, c * chord_len - 0.6, note, pan=pans[k])
    x = cfilter(x, [("hp", 45, 0.7), ("lp", 5000, 0.7)])
    return reverb(cv, x, rt60=3.5, wet=0.45, damp_hz=3500)


def mus_boite_a_musique(cv: Canvas):
    rng, beat = cv.rng, 0.55
    check_meter(cv, 48, beat)
    x = cv.zeros()
    melody = (("E5", 1), ("G5", 1), ("C6", 1), ("B5", 2), ("G5", 1), ("A5", 1), ("F5", 1), ("A5", 1),
              ("G5", 3), ("E5", 1), ("G5", 1), ("C6", 1), ("D6", 2), ("B5", 1), ("C6", 1), ("A5", 1),
              ("F5", 1), ("G5", 3), ("A5", 1), ("C6", 1), ("A5", 1), ("G5", 2), ("E5", 1), ("F5", 1),
              ("A5", 1), ("D5", 1), ("E5", 3), ("D5", 1), ("F5", 1), ("A5", 1), ("G5", 2), ("B4", 1),
              ("D5", 1), ("E5", 1), ("D5", 1), ("C5", 3))
    b = 0.0
    for name, ln in melody:
        cv.place(x, b * beat + rng.normal(0, 0.006), musicbox_note(rng, hz(name), rng.uniform(0.75, 0.9)),
                 pan=0.15)
        b += ln
    assert abs(b - 48) < 1e-9
    harmony = (("C4", "E4", "G4"), ("G3", "D4", "G4"), ("F3", "A3", "C4"), ("C4", "E4", "G4"),
               ("C4", "E4", "G4"), ("G3", "B3", "D4"), ("F3", "A3", "C4"), ("G3", "B3", "D4"),
               ("A3", "C4", "E4"), ("E3", "G3", "B3"), ("D3", "F3", "A3"), ("A3", "C4", "E4"),
               ("D3", "F3", "A3"), ("G3", "B3", "D4"), ("G3", "B3", "F4"), ("C4", "E4", "G4"))
    for bar, (root, third, fifth) in enumerate(harmony):
        t = bar * 3 * beat
        cv.place(x, t + rng.normal(0, 0.006), musicbox_note(rng, hz(root), 0.5), pan=-0.25)
        cv.place(x, t + beat + rng.normal(0, 0.006), musicbox_note(rng, hz(third), 0.32), pan=-0.1)
        cv.place(x, t + 2 * beat + rng.normal(0, 0.006), musicbox_note(rng, hz(fifth), 0.32), pan=-0.05)
    x = cfilter(x, [("lp", 7000, 0.7), ("highshelf", 4000, 0.707, -3.0)])
    return reverb(cv, x, rt60=1.6, wet=0.28, damp_hz=4500)


def mus_bols_tibetains(cv: Canvas):
    rng = cv.rng
    x = cv.zeros()
    strikes = ((0.8, 0, 1.0, -0.3), (8.3, 1, 0.8, 0.35), (15.9, 2, 0.75, 0.0),
               (23.4, 0, 0.85, -0.2), (30.6, 2, 0.7, 0.25), (38.5, 1, 0.8, -0.35))
    for t0, b, vel, pan in strikes:
        cv.place(x, t0, bowl_strike(rng, BOWLS[b], vel), pan=pan)
    # sustained "rubbed" drone: every frequency completes a whole number of cycles per loop
    f0 = BOWLS[0][0]
    t = cv.t
    drone = np.zeros(cv.n)
    for ratio, amp, split in ((1.0, 1.0, 0.9), (2.71, 0.3, 1.6)):
        fa, fb = cv.qhz(f0 * ratio), cv.qhz(f0 * ratio + split)
        drone += amp * 0.5 * (np.sin(2 * np.pi * fa * t) + np.sin(2 * np.pi * fb * t + 1.0))
    drone *= 0.75 + 0.25 * cv.lfo(3, 0.5)
    x += undb(-14) * rms(x) / rms(drone) * np.stack([drone, np.roll(drone, 30)])
    return reverb(cv, x, rt60=4.0, wet=0.35, damp_hz=3000)


def pad_voice(rng, cv, t0, f0, dur, vel, sweep_cycles, sweep_phase):
    """Warm pad voice; brightness follows a loop-periodic filter sweep."""
    m = int(dur * SR)
    t = np.arange(m) / SR
    nmax = max(1, min(30, int(6000 / f0)))
    dark = wavetable([n ** -2.0 * lpm(n * f0, 500.0, 2) for n in range(1, nmax + 1)], rng=rng)
    bright = wavetable([n ** -1.0 * lpm(n * f0, 1600.0, 2) for n in range(1, nmax + 1)], rng=rng)
    mix = 0.5 + 0.5 * np.sin(2 * np.pi * sweep_cycles * (t0 + t) / cv.seconds + sweep_phase)
    out = np.zeros((2, m))
    for cents, pan in ((-9.0, -0.6), (-2.0, 0.0), (8.0, 0.6)):
        fr = np.full(m, f0 * 2.0 ** (cents / 1200.0))
        ph = rng.uniform()
        v = (1.0 - mix) * wt_read(dark, fr, ph) + 0.6 * mix * wt_read(bright, fr, ph)
        gl, gr = pan_gains(pan)
        out[0] += gl * v
        out[1] += gr * v
    return out * env_ar(m, 3.0, 3.5) * vel / 3.0


def mus_nappes_apaisantes(cv: Canvas):
    rng, f = cv.rng, cv.f
    chord_len = cv.seconds / 4
    x = cv.zeros()
    chords = (("A2", "E3", "G#3", "B3", "C#4"), ("F#2", "C#3", "E3", "A3", "G#4"),
              ("D2", "A2", "F#3", "C#4", "E4"), ("E2", "B2", "F#3", "A3", "C#4"))
    phase = rng.uniform(0, 2 * np.pi)
    for c, ch in enumerate(chords):
        t0 = c * chord_len - 1.5
        for k, name in enumerate(ch):
            vel = 0.8 if k == 0 else 0.55
            cv.place(x, t0, pad_voice(rng, cv, t0, hz(name), chord_len + 4.0, vel, 2, phase))
        sub = tone(np.full(int((chord_len + 4.0) * SR), hz(ch[0])), ())
        cv.place(x, t0, sub * env_ar(sub.size, 3.0, 3.5) * 0.25)
    air = cv.noise(tilt(f, -3.0) * hpm(f, 500) * lpm(f, 2500), corr=0.3) * (0.6 + 0.4 * cv.lfo(3, phase))
    x = unit_rms(x) + undb(-28) * air
    x = cfilter(x, [("lp", 6000, 0.7)])
    return reverb(cv, x, rt60=4.5, wet=0.5, damp_hz=3000)


# ----------------------------------------------------------------------------
# Registry: id -> (loop length in seconds, recipe)
# Lengths differ (23-47 s) so layers never phase-lock; nature loops are mostly
# prime numbers of seconds, music loops are whole numbers of bars.
# ----------------------------------------------------------------------------

RECIPES = {
    "sons": {
        "eau-vive": (31.0, snd_eau_vive),
        "oiseaux": (41.0, snd_oiseaux),
        "vent": (37.0, snd_vent),
        "pluie-douce": (29.0, snd_pluie_douce),
        "ruisseau": (34.0, snd_ruisseau),
        "vagues": (43.0, snd_vagues),
        "feu-de-camp": (26.0, snd_feu_de_camp),
        "grillons": (23.0, snd_grillons),
        "chouette": (39.0, snd_chouette),
    },
    "musiques": {
        "piano-doux": (35.2, mus_piano_doux),            # 8 bars of 4/4, beat 1.1 s
        "harpe": (40.32, mus_harpe),                     # 16 bars of 6/8, eighth 0.42 s
        "flute": (36.8, mus_flute),                      # 8 bars of 4/4, beat 1.15 s
        "guitare-douce": (28.8, mus_guitare_douce),      # 8 bars of 4/4, beat 0.9 s
        "cordes-lentes": (44.8, mus_cordes_lentes),      # 8 bars of 4/4, beat 1.4 s
        "boite-a-musique": (26.4, mus_boite_a_musique),  # 16 bars of 3/4, beat 0.55 s
        "bols-tibetains": (45.5, mus_bols_tibetains),    # free time
        "nappes-apaisantes": (42.5, mus_nappes_apaisantes),  # 4 chords of 10.625 s
    },
}


# ----------------------------------------------------------------------------
# Encoding and verification
# ----------------------------------------------------------------------------

OPUS_FRAME = 960          # 20 ms packets
OPUS_ENCODER_DELAY = 312  # libopus look-ahead at 48 kHz (checked against the OpusHead it writes)
PREROLL_FRAMES = 16       # 320 ms of loop tail encoded before sample 0 (encoder state settles)
POSTROLL_FRAMES = 4       # 80 ms of loop head encoded after the last sample, then dropped
WARMUP_FRAMES = 16        # copies of the loop's last packets decoded (and skipped) before sample 0


def _crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else r << 1
        table.append(r & 0xFFFFFFFF)
    return table


OGG_CRC = _crc_table()


def ogg_crc(data) -> int:
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ OGG_CRC[((crc >> 24) & 0xFF) ^ b]
    return crc


def ogg_packets(data: bytes):
    """Split a single-stream Ogg file into (serial, packets, last granule)."""
    pos, packets, partial, serial, granule = 0, [], b"", None, None
    while pos < len(data):
        if data[pos:pos + 4] != b"OggS":
            raise ValueError("not an Ogg page")
        granule = int.from_bytes(data[pos + 6:pos + 14], "little", signed=True)
        serial = int.from_bytes(data[pos + 14:pos + 18], "little")
        nseg = data[pos + 26]
        body = pos + 27 + nseg
        for lv in data[pos + 27:pos + 27 + nseg]:
            partial += data[body:body + lv]
            body += lv
            if lv < 255:
                packets.append(partial)
                partial = b""
        pos = body
    return serial, packets, granule


def opus_packet_samples(p: bytes) -> int:
    """Duration of an Opus packet in 48 kHz samples (RFC 6716 TOC byte)."""
    config, code = p[0] >> 3, p[0] & 3
    if config < 12:
        size = (480, 960, 1920, 2880)[config & 3]
    elif config < 16:
        size = (480, 960)[config & 1]
    else:
        size = (120, 240, 480, 960)[config & 3]
    frames = 1 if code == 0 else 2 if code in (1, 2) else p[1] & 0x3F
    return size * frames


def ogg_write(serial, head, tags, audio):
    """Mux Opus packets into Ogg pages (about 1 s per page)."""
    out, seq = bytearray(), 0

    def page(packets, granule, flags):
        nonlocal seq
        lacing, body = bytearray(), bytearray()
        for p in packets:
            lacing += bytes([255]) * (len(p) // 255) + bytes([len(p) % 255])
            body += p
        if len(lacing) > 255:
            raise ValueError("page overflow")
        pg = bytearray(b"OggS") + bytes([0, flags]) + granule.to_bytes(8, "little", signed=True) \
            + serial.to_bytes(4, "little") + seq.to_bytes(4, "little") + bytes(4) + bytes([len(lacing)]) \
            + lacing + body
        pg[22:26] = ogg_crc(pg).to_bytes(4, "little")
        out.extend(pg)
        seq += 1

    page([head], 0, 0x02)
    page([tags], 0, 0x00)
    granule, group, lace = 0, [], 0
    for i, p in enumerate(audio):
        need = len(p) // 255 + 1
        if group and (len(group) == 50 or lace + need > 255):
            page(group, granule, 0x00)
            group, lace = [], 0
        group.append(p)
        lace += need
        granule += opus_packet_samples(p)
    page(group, granule, 0x04)
    return bytes(out)


def ffmpeg_opus(x, title, bitrate=OPUS_BITRATE, comment=COMMENT):
    pcm = np.ascontiguousarray(x.T.astype("<f4"))
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "pipe:0",
           "-c:a", "libopus", "-b:a", bitrate, "-vbr", "on", "-application", "audio",
           "-frame_duration", "20", "-map_metadata", "-1",
           "-metadata", f"title={title}", "-metadata", f"comment={comment}",
           "-fflags", "+bitexact", "-flags:a", "+bitexact", "-f", "ogg", "pipe:1"]
    return subprocess.run(cmd, input=pcm.tobytes(), capture_output=True, check=True).stdout


def encode_opus(x, out_path: Path, title: str, plain=False, bitrate=OPUS_BITRATE, comment=COMMENT):
    """Encode a loop to Ogg Opus so that it decodes to exactly N looping samples.

    Plain ffmpeg output starts the encoder from silence and pads the end with
    zeros: both edges are coded as transients (an HF burst at the loop point),
    and a decoder that ignores the end-trim granule (flutter_soloud's streaming
    WavStream does) plays ~13 ms of padding before looping. Even without
    those, the codec error is not periodic: a cold decoder at the file start
    and the warm decoder at the file end leave a small step at the join.

    So we:
      1. encode the circular extension [loop tail | loop | loop head], so the
         first and last loop frames are coded with real context on both sides;
      2. keep the packets that cover exactly the loop (N samples);
      3. prepend copies of the loop's *own last packets* as warm-up and set the
         OpusHead pre-skip to their length. The decoder discards them, but it
         enters sample 0 in (almost) the state it leaves sample N-1, so the
         MDCT overlap-add across the join behaves like an internal frame
         boundary. 16 frames are used because CELT's inter-frame energy
         prediction only decays by ~0.5 per 20 ms frame;
      4. mux with granules that match the packet total: no end-trim needed.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    n = x.shape[1]
    if plain:
        out_path.write_bytes(ffmpeg_opus(x, title, bitrate, comment))
        return
    lead = PREROLL_FRAMES * OPUS_FRAME  # decoded samples before x[0] in the encoded stream
    preroll = lead - OPUS_ENCODER_DELAY  # input samples before x[0] (the encoder delays by 312)
    idx = (np.arange(preroll + n + POSTROLL_FRAMES * OPUS_FRAME) - preroll) % n
    serial, packets, _ = ogg_packets(ffmpeg_opus(x[:, idx], title, bitrate, comment))
    head, tags, audio = packets[0], packets[1], packets[2:]
    if head[:8] != b"OpusHead" or tags[:8] != b"OpusTags":
        raise ValueError("unexpected Ogg Opus header")
    if int.from_bytes(head[10:12], "little") != OPUS_ENCODER_DELAY:
        raise ValueError("unexpected libopus encoder delay")
    if sum(opus_packet_samples(p) for p in audio[:PREROLL_FRAMES]) != lead:
        raise ValueError("unexpected Opus frame size")
    loop, total = [], 0
    for p in audio[PREROLL_FRAMES:]:
        if total >= n:
            break
        loop.append(p)
        total += opus_packet_samples(p)
    if total != n:
        raise ValueError("loop length is not a whole number of Opus frames")
    warm, pre_skip = [], 0
    for p in reversed(loop):
        if pre_skip >= WARMUP_FRAMES * OPUS_FRAME:
            break
        warm.insert(0, p)
        pre_skip += opus_packet_samples(p)
    head = head[:10] + pre_skip.to_bytes(2, "little") + head[12:]
    out_path.write_bytes(ogg_write(serial, head, tags, warm + loop))


def opus_needs_end_trim(path: Path):
    """True if the packets decode to more samples than the final granule says."""
    _, packets, granule = ogg_packets(path.read_bytes())
    return sum(opus_packet_samples(p) for p in packets[2:]) != granule


def write_wav(x, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.ascontiguousarray(x.T.astype("<f4"))
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(SR),
                    "-ac", "2", "-i", "pipe:0", "-c:a", "pcm_f32le", str(path)], input=pcm.tobytes(), check=True)


def decode(path: Path):
    """Decode with the reference libopus decoder (honours pre-skip and end trim)."""
    res = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-c:a", "libopus", "-i", str(path),
                          "-f", "f32le", "-ac", "2", "-ar", str(SR), "pipe:1"], capture_output=True, check=True)
    return np.frombuffer(res.stdout, dtype="<f4").reshape(-1, 2).T.astype(np.float64)


def ffmpeg_ebur128(path: Path):
    res = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128=peak=true",
                          "-f", "null", "-"], capture_output=True, text=True)
    tail = res.stderr[res.stderr.rfind("Summary:"):]
    i = re.search(r"I:\s+(-?[\d.]+) LUFS", tail)
    p = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    return (float(i.group(1)) if i else None, float(p.group(1)) if p and p.group(1) != "-inf" else None)


def seam_metrics(y, win=240, ctx=10):
    """Measure the loop join of two concatenated copies against the rest.

    step:  |y[N] - y[N-1]| across the join of [y | y] vs. every other pair of
           adjacent samples.
    click: energy of the 2nd difference (a crude high-pass that makes clicks
           stand out) in the 5 ms window centred on the join, relative to the
           median of the 2*ctx neighbouring windows (+-50 ms). The same local
           ratio is computed for every 5 ms window of the loop so the join can
           be ranked against ordinary content (note onsets, crackles...).
    """
    n = y.shape[1]
    two = np.concatenate([y, y], axis=1)
    steps = np.abs(np.diff(two, axis=1)).max(axis=0)
    join_step = float(steps[n - 1])
    body = steps[:n - 1]
    # The 2nd difference of [y | y] around the join equals the circular one of y.
    hf = np.square(np.roll(y, -1, axis=1) - 2.0 * y + np.roll(y, 1, axis=1)).sum(axis=0)
    hf = np.roll(hf, win // 2)[: (n // win) * win]
    e = hf.reshape(-1, win).sum(axis=1) + 1e-30  # e[0] is centred on the join
    neigh = np.stack([np.roll(e, k) for k in range(-ctx, ctx + 1) if k != 0])
    r = 10.0 * np.log10(e / np.median(neigh, axis=0))
    others = r[1:]
    return {
        "join_step": join_step,
        "step_median": float(np.median(body)),
        "step_p99": float(np.percentile(body, 99)),
        "step_rank_pct": float((body < join_step).mean() * 100),
        "click_join_db": float(r[0]),
        "click_p99_db": float(np.percentile(others, 99)),
        "click_max_db": float(others.max()),
        "click_rank_pct": float((others < r[0]).mean() * 100),
    }


def edge_error_db(x, y, edge=0.01, context=0.2):
    """Coding error in the first/last `edge` s vs. the next `context` s inside (dB).

    Compares the codec error right at the file boundaries with the error just
    inside them (similar signal level), so ~0 dB means the edges are coded as
    well as the rest.
    """
    e = np.square(y - x).sum(axis=0)
    k, c = int(edge * SR), int(context * SR)
    at_edges = np.concatenate([e[:k], e[-k:]]).mean()
    inside = np.concatenate([e[k:c], e[-c:-k]]).mean() + 1e-30
    return float(10 * np.log10(at_edges / inside + 1e-30))


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------

def load_catalog():
    """(kind, id, free) of every loop to make. Landscape ambiances (`paysage`) come from the
    landscape videos (make_ambiance.py) and the variants of the event sounds (`lecture:
    evenements`, contract § 11) from the real thunder (make_thunder.py), not from here."""
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    items = []
    for kind in ("sons", "musiques"):
        for entry in cat[kind]:
            if entry.get("paysage") or entry.get("lecture") == "evenements":
                continue
            if entry["id"] not in RECIPES[kind]:
                raise SystemExit(f"no recipe for {kind}/{entry['id']}")
            items.append((kind, entry["id"], bool(entry["gratuit"])))
    return items


def event_sounds():
    """Ids of the catalog's event sounds (their old looping file, if any, is removed)."""
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    return [e["id"] for e in cat["sons"] if e.get("lecture") == "evenements"]


def out_paths(kind, item_id, free):
    rel = Path(kind) / f"{item_id}.ogg"
    return (FREE_ROOT if free else PREMIUM_ROOT) / rel, (PREMIUM_ROOT if free else FREE_ROOT) / rel


def build_one(args):
    kind, item_id, free, wav_dir, plain = args
    t_start = time.time()
    seconds, recipe = RECIPES[kind][item_id]
    cv = Canvas(seconds, zlib.crc32(item_id.encode()))
    x = recipe(cv)
    x, info = finalize(x)
    x32 = x.astype(np.float32)
    dest, stale = out_paths(kind, item_id, free)
    if stale.exists():
        stale.unlink()
    encode_opus(x32, dest, f"Eventide placeholder - {item_id}", plain=plain)
    if wav_dir:
        write_wav(x32, Path(wav_dir) / kind / f"{item_id}.wav")
    row = measure(kind, item_id, free, dest, x32.astype(np.float64))
    row.update({"true_peak_dbtp": round(info["true_peak_dbtp"], 2), "limited": info["limited"],
                "elapsed_s": round(time.time() - t_start, 1)})
    return row


def measure(kind, item_id, free, dest: Path, x=None):
    seconds = RECIPES[kind][item_id][0]
    y = decode(dest)
    i_lufs, peak = ffmpeg_ebur128(dest)
    ok = x is not None and x.shape == y.shape
    return {
        "kind": kind, "id": item_id, "free": free, "seconds": seconds, "path": str(dest.relative_to(REPO)),
        "bytes": dest.stat().st_size, "samples": int(round(seconds * SR)), "decoded_samples": int(y.shape[1]),
        "needs_end_trim": opus_needs_end_trim(dest), "lufs_circular": round(loudness_lufs(y), 2),
        "ffmpeg_lufs": i_lufs, "decoded_peak_dbfs": peak,
        "decoded_true_peak_dbtp": round(float(todb(true_peak(y))), 2),
        "seam_src": seam_metrics(x) if x is not None else None, "seam_dec": seam_metrics(y),
        "edge_err_db": edge_error_db(x, y) if ok else None, "true_peak_dbtp": None, "limited": None,
        "elapsed_s": 0.0,
    }


def check_one(args):
    kind, item_id, free = args[:3]
    return measure(kind, item_id, free, out_paths(kind, item_id, free)[0])


def make_silence():
    dest = FREE_ROOT / "silence.ogg"
    encode_opus(np.zeros((2, SR), dtype=np.float32), dest, "Eventide - silence (1 s)")
    return dest


def fmt(v, spec):
    return format(v, spec) if v is not None else format(float("nan"), spec)


def print_report(rows):
    hdr = (f"{'id':<19}{'tier':<8}{'len s':>6}{'KiB':>5}{'LUFS':>6}{'ffmpg':>6}{'TPdec':>6}{'N ok':>5}"
           f"{'trim':>5} |{'step':>7}{'p99':>7}{'rk%':>5} |{'click':>6}{'p99':>5}{'max':>5}{'rk%':>6}"
           f" |{'src':>5}{'edge':>6}")
    print("step = |sample jump| at the join vs p99 of all jumps; click = 5 ms HF energy at the join vs its")
    print("+-50 ms neighbourhood (dB), p99/max over every 5 ms window; src = same click metric before")
    print("encoding; edge = coding error in first/last 10 ms vs the 10-200 ms inside (dB); trim = end-trim needed")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        d, s = r["seam_dec"], r["seam_src"]
        print(f"{r['id']:<19}{'free' if r['free'] else 'premium':<8}{r['seconds']:>6.2f}{r['bytes'] / 1024:>5.0f}"
              f"{r['lufs_circular']:>6.1f}{fmt(r['ffmpeg_lufs'], '6.1f')}{r['decoded_true_peak_dbtp']:>6.1f}"
              f"{'yes' if r['decoded_samples'] == r['samples'] else 'NO':>5}"
              f"{'yes' if r['needs_end_trim'] else 'no':>5} |"
              f"{d['join_step']:>7.4f}{d['step_p99']:>7.4f}{d['step_rank_pct']:>5.0f} |"
              f"{d['click_join_db']:>6.1f}{d['click_p99_db']:>5.1f}{d['click_max_db']:>5.1f}"
              f"{d['click_rank_pct']:>6.1f} |{fmt(s['click_join_db'] if s else None, '5.1f')}"
              f"{fmt(r['edge_err_db'], '6.1f')}")
    total = sum(r["bytes"] for r in rows)
    free = sum(r["bytes"] for r in rows if r["free"])
    print(f"\nTotal {total / 1024:.0f} KiB (bundled in app: {free / 1024:.0f} KiB, "
          f"premium for S3: {(total - free) / 1024:.0f} KiB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="ids to (re)generate")
    ap.add_argument("--check-only", action="store_true", help="only decode and measure existing files")
    ap.add_argument("--wav-dir", help="also write the float WAV masters here (not committed)")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--report", help="write the measurements as JSON to this path")
    ap.add_argument("--plain-opus", action="store_true",
                    help="plain ffmpeg encode without the pre-roll/remux (for comparison only)")
    a = ap.parse_args()

    events = event_sounds()
    wanted = set(a.only or [])
    if wanted & set(events):
        raise SystemExit("event sounds (tonnerre) are made by make_thunder.py")
    items = [(k, i, free, a.wav_dir, a.plain_opus) for k, i, free in load_catalog()
             if not a.only or i in wanted]
    if a.only and not items:
        raise SystemExit("unknown id in --only")
    fn = check_one if a.check_only else build_one
    t0 = time.time()
    with ProcessPoolExecutor(max_workers=max(1, a.jobs)) as pool:
        rows = list(pool.map(fn, items))
    if not a.check_only and not a.only and not a.plain_opus:
        make_silence()
    if not a.check_only:
        # An event sound has no looping file (its variants, made by make_thunder.py, replace it).
        for sound in events:
            for root in (FREE_ROOT, PREMIUM_ROOT):
                old = root / "sons" / f"{sound}.ogg"
                if old.exists():
                    old.unlink()
                    print(f"removed {old.relative_to(REPO)} (an event sound: variants only)")
        write_remote_manifest()
    if rows:
        print_report(rows)
    print(f"done in {time.time() - t0:.0f} s")
    if a.report:
        Path(a.report).write_text(json.dumps(rows, indent=2), encoding="utf-8")
    bad = [r["id"] for r in rows if r["decoded_samples"] != r["samples"]]
    if bad:
        print("WARNING: decoded length differs from the loop length: " + ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
