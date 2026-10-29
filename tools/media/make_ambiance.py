#!/usr/bin/env python3
"""Landscape ambiances for Eventide: the source video's own sound as a long seamless loop,
without thunder (API contract § 11, catalog sounds with a ``paysage`` field).

The landscape videos play muted (contract § 8); their soundtrack becomes a catalog sound
(``ambiance-<landscape>``) played by the app's mixer, so pausing stops the sound and the
picture goes on. The sources are short (10 s for the Veo videos), and some carry thunder,
which the app now plays as separate events (``tonnerre``, at irregular intervals, never twice
the same). So, per item:

  1. **Decode** the first audio stream (48 kHz stereo float), drop 0.1 s at each edge.
  2. **Rumble suppression**: the band below ~460 Hz (complementary zero-phase split, the bands
     add back to the input exactly) is gain-ridden down to its own floor (20th percentile of
     its 100 ms level, +1.5 dB, 50 ms look-ahead): distant thunder rumbles and rolls
     disappear, the body of the rain and of the water stays.
  3. **Thunder detection** on what is left: the 100 ms level of the 700-4000 Hz band (the
     body of the rain or of the water, steady within +-1 dB) against its floor (+3 dB), plus
     the raw rumble band (25-180 Hz, +9 dB: a strong thunder, even if its roll was ridden
     down); each detection is widened by 0.3 s before and 1 s after (the tail). Drop impacts
     (4-14 kHz) are not thunder and are not looked at. The rest is the pool of thunder-free
     material.
  4. **Texture synthesis** on a circular time axis of N samples (N > 60 s, a whole number of
     20 ms Opus frames): grains of 0.8-1.8 s drawn at random from the pool, each with its own
     playback speed (+-2.5 %, FFT resampling with margins) and a random left/right swap, joined
     by 0.3 s equal-power (sine/cosine) cross-fades; the last grain cross-fades into the first
     one, so the loop has no seam. A grain never reuses the material of the two grains before
     it, and never continues the previous grain where it stopped (no comb filtering). Several
     independent streams can be summed (``streams``, equal power): denser, heavier rain.
  5. **Level** like every other loop (generate_audio.finalize): -23 LUFS (BS.1770-4, circular),
     true peak <= -1 dBTP.
  6. **Encoding** like every other loop (generate_audio.encode_opus: circular pre-roll, warm-up
     packets, exact N samples), Ogg Opus at 96 kbit/s (recorded rain and water are dense noise:
     more bits than the 64 kbit/s of the synthetic loops).
  7. **Measurements** on the decoded file: length, loudness, true peak, join (step and click
     metrics of generate_audio.seam_metrics), thunder left (100 ms rumble and roll levels above
     their median, against the source), periodicity (largest autocorrelation of the 50 ms level
     envelope at lags of 1 to 30 s, against the pool simply looped).

Destinations: the catalog decides (``gratuit``): ``app/assets/audio/sons/<id>.ogg`` (free,
bundled) or ``content/audio/sons/<id>.ogg`` (Premium, S3); third-party test material goes to
``medias-test/audio/sons/<id>.ogg`` only (demo build, never content/ nor app/assets/). The
script then rewrites ``app/assets/landscapes/remote.json`` (remote_manifest.py).

Usage (from the repository root):
  python3 tools/media/make_ambiance.py
  python3 tools/media/make_ambiance.py --only ambiance-pluie-ville
  python3 tools/media/make_ambiance.py --check-only
  python3 tools/media/make_ambiance.py --wav-dir /tmp/wav --report r.json

Media files are untrusted input: they are only read through ffmpeg/ffprobe. Deterministic:
each item has its own seed (crc32 of its id).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from generate_audio import (
    SR,
    decode,
    encode_opus,
    ffmpeg_ebur128,
    finalize,
    loudness_lufs,
    opus_needs_end_trim,
    seam_metrics,
    todb,
    true_peak,
    write_wav,
)
from remote_manifest import write_remote_manifest

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "app" / "assets" / "catalog.json"
FREE_DIR = REPO / "app" / "assets" / "audio" / "sons"
PREMIUM_DIR = REPO / "content" / "audio" / "sons"
TEST_DIR = REPO / "medias-test" / "audio" / "sons"

BITRATE = "96k"
EDGE_TRIM_S = 0.1
XFADE_S = 0.30
MARGIN_S = 0.05                # resampling margins around each grain
RUMBLE_SPLIT_HZ = (350.0, 600.0)   # raised-cosine crossover of the rumble/roll band
RUMBLE_HEADROOM_DB = 1.5
FLOOR_PERCENTILE = 20
DETECT = {                     # band (Hz) -> dB above its floor that means thunder
    "body": ((700.0, 4000.0), 3.0),
}
RUMBLE_DETECT_DB = 9.0         # raw rumble band (25-180 Hz) this far above its floor
DETECT_PRE_S, DETECT_POST_S = 0.3, 1.0
COMMENT = ("Eventide landscape ambiance - the landscape video's own soundtrack, thunder removed, "
           "re-synthesised as a seamless loop by tools/media/make_ambiance.py")


@dataclass(frozen=True)
class Ambiance:
    id: str
    source: str                          # relative to the repository
    seconds: float                       # loop length: > 60 s, a whole number of 20 ms frames
    grain_s: tuple[float, float] = (0.8, 1.8)
    speed: tuple[float, float] = (0.975, 1.025)
    streams: int = 1                     # independent grain streams summed (denser texture)
    test_only: bool = False              # third-party: medias-test/ only


ITEMS = [
    # Generated by the product owner with Google Gemini (Veo), 28 October 2026 (commercial use
    # to be confirmed, content/LICENCES.md). 10 s each.
    Ambiance("ambiance-cascade-foret", "medias-bruts/videos/cascade-foret.mp4", 61.0),
    # Rain on the window, a thunderclap from 3.3 s to the end: under 3 s of clean rain, hence
    # shorter grains. Two streams: the torrential rain the product owner asked for.
    Ambiance("ambiance-pluie-ville", "medias-bruts/videos/pluie-ville.mp4", 67.0,
             grain_s=(0.5, 1.1), streams=2),
    # Third-party test material (YouTube): internal tests only, demo build only.
    Ambiance("ambiance-toits-pluie", "medias-test/originaux/toits-pluie.mp4", 71.0, test_only=True),
]


# ----------------------------------------------------------------------------
# Signal helpers
# ----------------------------------------------------------------------------

def load(path: Path) -> np.ndarray:
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-map", "0:a:0", "-vn", "-sn", "-dn",
         "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    x = np.frombuffer(out, "<f4").reshape(-1, 2).T.astype(np.float64)
    k = int(EDGE_TRIM_S * SR)
    return x[:, k:-k]


def band_mask(f: np.ndarray, lo: float, hi: float, width: float = 0.25) -> np.ndarray:
    """Zero-phase band-pass magnitude with raised-cosine edges (width in octaves)."""
    lf = np.log2(np.maximum(f, 1.0))
    m = np.ones_like(f)
    for edge, rising in ((lo, True), (hi, False)):
        u = np.clip((lf - (np.log2(edge) - width / 2)) / width, 0.0, 1.0)
        ramp = 0.5 - 0.5 * np.cos(np.pi * u)
        m *= ramp if rising else 1.0 - ramp
    return m


def band(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    n = x.shape[-1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x, axis=-1) * band_mask(f, lo, hi), n=n, axis=-1)


def levels_db(x: np.ndarray, win_s: float = 0.1, hop_s: float = 0.05) -> np.ndarray:
    """RMS level (dB) of a (2, n) or (n,) signal over sliding windows."""
    p = np.square(x).mean(axis=0) if x.ndim == 2 else np.square(x)
    w, h = int(win_s * SR), int(hop_s * SR)
    cs = np.concatenate([[0.0], np.cumsum(p)])
    starts = np.arange(0, p.size - w + 1, h)
    return 10.0 * np.log10((cs[starts + w] - cs[starts]) / w + 1e-20)


def suppress_rumble(x: np.ndarray) -> tuple[np.ndarray, float]:
    """Rides the band below ~160 Hz down to its own floor (+RUMBLE_HEADROOM_DB)."""
    n = x.shape[1]
    f = np.fft.rfftfreq(n, 1.0 / SR)
    lo_hz, hi_hz = RUMBLE_SPLIT_HZ
    u = np.clip((np.log2(np.maximum(f, 1.0)) - np.log2(lo_hz)) / (np.log2(hi_hz) - np.log2(lo_hz)), 0, 1)
    low_mask = 0.5 + 0.5 * np.cos(np.pi * u)          # 1 below 120 Hz, 0 above 200 Hz
    low = np.fft.irfft(np.fft.rfft(x, axis=-1) * low_mask, n=n, axis=-1)
    rest = x - low                                     # complementary: low + rest == x
    hop = int(0.01 * SR)
    env = levels_db(low, win_s=0.1, hop_s=0.01)
    target = np.percentile(env, FLOOR_PERCENTILE) + RUMBLE_HEADROOM_DB
    gain = np.minimum(0.0, target - env)               # dB, <= 0
    look = 5                                           # 50 ms look-ahead: catch the onsets
    ahead = gain.copy()
    for k in range(1, look + 1):
        ahead[:-k] = np.minimum(ahead[:-k], gain[k:])
    smooth = np.empty_like(ahead)
    att, rel = np.exp(-hop / (0.03 * SR)), np.exp(-hop / (0.4 * SR))
    g = 0.0
    for i, target_db in enumerate(ahead):
        coef = att if target_db < g else rel
        g = coef * g + (1 - coef) * target_db
        smooth[i] = g
    centres = np.arange(smooth.size) * hop + int(0.05 * SR)
    curve = np.interp(np.arange(n), centres, smooth)
    return rest + low * 10.0 ** (curve / 20.0), float(-smooth.min())


def detect_thunder(raw: np.ndarray, clean: np.ndarray) -> tuple[np.ndarray, dict]:
    """Per-sample mask of thunder (True) on the rumble-suppressed signal."""
    hop = int(0.05 * SR)
    flags = None
    info = {}
    for name, ((lo, hi), tol) in DETECT.items():
        lev = levels_db(band(clean, lo, hi))
        floor = np.percentile(lev, FLOOR_PERCENTILE)
        hit = lev > floor + tol
        info[name] = {"floor_db": round(float(floor), 1), "max_above_db": round(float(lev.max() - floor), 1)}
        flags = hit if flags is None else flags | hit
    rum = levels_db(band(raw, 25.0, 180.0))
    rfloor = np.percentile(rum, FLOOR_PERCENTILE)
    flags |= rum > rfloor + RUMBLE_DETECT_DB
    info["rumble_raw"] = {"floor_db": round(float(rfloor), 1), "max_above_db": round(float(rum.max() - rfloor), 1)}
    mask = np.zeros(raw.shape[1], bool)
    w = int(0.1 * SR)
    pre, post = int(DETECT_PRE_S * SR), int(DETECT_POST_S * SR)
    for i in np.flatnonzero(flags):
        a = i * hop
        mask[max(0, a - pre): min(mask.size, a + w + post)] = True
    return mask, info


def runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """[start, end) of each run of True."""
    edges = np.diff(np.concatenate([[0], mask.astype(np.int8), [0]]))
    return list(zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1), strict=True))


def resample(seg: np.ndarray, speed: float) -> np.ndarray:
    """Plays ``seg`` ``speed`` times faster (FFT resampling; the caller cuts the margins)."""
    n = seg.shape[1]
    m = int(round(n / speed))
    spec = np.fft.rfft(seg, axis=-1)
    out = np.zeros((seg.shape[0], m // 2 + 1), complex)
    k = min(spec.shape[1], out.shape[1])
    out[:, :k] = spec[:, :k]
    return np.fft.irfft(out, n=m, axis=-1) * (m / n)


# ----------------------------------------------------------------------------
# Texture synthesis
# ----------------------------------------------------------------------------

@dataclass
class Grain:
    at: int        # output position of the start of the fade-in
    length: int    # output samples until the next grain starts
    src: int       # source position (pool signal) of the first sample used
    span: int      # source samples covered (length + fade, at this speed)
    speed: float
    swap: bool


def plan_grains(n_out: int, pool_runs: list[tuple[int, int]], item: Ambiance, rng) -> list[Grain]:
    x = int(XFADE_S * SR)
    gmin, gmax = (int(s * SR) for s in item.grain_s)
    count = max(2, int(round(n_out / ((gmin + gmax) / 2))))
    lengths = rng.uniform(gmin, gmax, count)
    lengths = np.floor(lengths * n_out / lengths.sum()).astype(int)
    lengths[-1] += n_out - lengths.sum()
    margin = int(MARGIN_S * SR)
    grains: list[Grain] = []
    at = 0
    for length in lengths:
        speed = float(rng.uniform(*item.speed))
        span = int(np.ceil((length + x) * speed))
        need = span + 2 * margin + 2
        fits = [(a, b) for a, b in pool_runs if b - a >= need]
        if not fits:
            raise SystemExit(f"{item.id}: no thunder-free run of {need / SR:.2f} s in the source")
        weights = np.array([b - a - need + 1 for a, b in fits], float)
        chosen = None
        for strict in (2, 1, 0):
            recent = grains[-strict:] if strict else []
            for _ in range(300):
                a, b = fits[rng.choice(len(fits), p=weights / weights.sum())]
                src = int(rng.integers(a + margin, b - margin - span))
                if any(abs(src - g.src) < max(g.span, span) for g in recent):
                    continue
                if grains:
                    prev = grains[-1]
                    if abs(src - (prev.src + int(prev.length * prev.speed))) < x + int(0.1 * SR):
                        continue
                chosen = src
                break
            if chosen is not None:
                break
        if chosen is None:
            raise SystemExit(f"{item.id}: pool too small for the grain constraints")
        grains.append(Grain(at, int(length), chosen, span, speed, bool(rng.random() < 0.5)))
        at += int(length)
    return grains


def render(pool: np.ndarray, grains: list[Grain], n_out: int) -> np.ndarray:
    x = int(XFADE_S * SR)
    margin = int(MARGIN_S * SR)
    u = (np.arange(x) + 0.5) / x
    fade_in, fade_out = np.sin(0.5 * np.pi * u), np.cos(0.5 * np.pi * u)
    out = np.zeros((2, n_out))
    for g in grains:
        seg = pool[:, g.src - margin: g.src + g.span + margin].copy()
        taper = np.hanning(2 * margin + 2)[1:-1]
        seg[:, :margin] *= taper[:margin]
        seg[:, -margin:] *= taper[margin:]
        res = resample(seg, g.speed)
        lead = int(round(margin / g.speed))
        piece = res[:, lead: lead + g.length + x]
        if piece.shape[1] < g.length + x:
            raise SystemExit("grain too short after resampling")
        if g.swap:
            piece = piece[::-1]
        piece = piece.copy()
        piece[:, :x] *= fade_in
        piece[:, -x:] *= fade_out
        idx = (g.at + np.arange(piece.shape[1])) % n_out
        out[:, idx] += piece
    return out


# ----------------------------------------------------------------------------
# Measurements
# ----------------------------------------------------------------------------

def periodicity(y: np.ndarray, circular: bool) -> float:
    """Largest autocorrelation of the 50 ms level envelope (700-4000 Hz) at lags of 1 to 30 s."""
    env = levels_db(band(y, 700.0, 4000.0), win_s=0.05, hop_s=0.05)
    env = env - env.mean()
    m = env.size
    if circular:
        spec = np.fft.rfft(env)
        ac = np.fft.irfft(np.abs(spec) ** 2, n=m)
    else:
        spec = np.fft.rfft(env, n=2 * m)
        ac = np.fft.irfft(np.abs(spec) ** 2, n=2 * m)[:m]
        ac = ac * m / np.maximum(m - np.arange(m), 1)
    ac = ac / ac[0]
    lo, hi = 20, min(600, m // 2)
    return float(ac[lo:hi].max()) if hi > lo else float("nan")


def thunder_left(y: np.ndarray) -> dict:
    """How far the 100 ms rumble and roll levels rise above their median (dB)."""
    out = {}
    for name, (lo, hi) in (("rumble", (25.0, 180.0)), ("roll", (180.0, 700.0))):
        lev = levels_db(band(y, lo, hi))
        out[name] = round(float(lev.max() - np.median(lev)), 1)
    return out


def reuse_spacing(grains: list[Grain]) -> dict:
    """Output time between two uses of overlapping source material (s)."""
    gaps = []
    for i, g in enumerate(grains):
        for h in reversed(grains[:i]):
            if h.src < g.src + g.span and g.src < h.src + h.span:
                gaps.append((g.at - h.at) / SR)
                break
    if not gaps:
        return {"count": 0}
    a = np.array(gaps)
    return {"count": int(a.size), "min_s": round(float(a.min()), 2), "median_s": round(float(np.median(a)), 2),
            "max_s": round(float(a.max()), 2), "cv": round(float(a.std() / a.mean()), 2)}


# ----------------------------------------------------------------------------
# Items
# ----------------------------------------------------------------------------

def destination(item: Ambiance, catalog: dict) -> tuple[Path, list[Path]]:
    sound = next((s for s in catalog["sons"] if s["id"] == item.id), None)
    if sound is None:
        raise SystemExit(f"{item.id}: not a sound of the catalog")
    paths = {"free": FREE_DIR / f"{item.id}.ogg", "premium": PREMIUM_DIR / f"{item.id}.ogg",
             "test": TEST_DIR / f"{item.id}.ogg"}
    key = "test" if item.test_only else ("free" if sound.get("gratuit") else "premium")
    return paths[key], [p for k, p in paths.items() if k != key]


def build(item: Ambiance, catalog: dict, wav_dir: Path | None) -> dict:
    t0 = time.time()
    dest, stale = destination(item, catalog)
    raw = load(REPO / item.source)
    clean, rumble_cut = suppress_rumble(raw)
    mask, detect_info = detect_thunder(raw, clean)
    margin = int(MARGIN_S * SR)
    pool_runs = [(int(a), int(b)) for a, b in runs(~mask)
                 if b - a >= int((item.grain_s[0] + XFADE_S) * SR * item.speed[1]) + 2 * margin + 2]
    pool_s = sum(b - a for a, b in pool_runs) / SR
    n = int(round(item.seconds * SR))
    if n % 960:
        raise SystemExit(f"{item.id}: {item.seconds} s is not a whole number of 20 ms Opus frames")
    rng = np.random.default_rng(zlib.crc32(item.id.encode()))
    x = np.zeros((2, n))
    all_grains = []
    for _ in range(item.streams):
        grains = plan_grains(n, pool_runs, item, rng)
        stream = render(clean, grains, n)
        x += np.roll(stream, int(rng.integers(0, n)), axis=1) / np.sqrt(item.streams)
        all_grains.append(grains)
    x, info = finalize(x)
    x32 = x.astype(np.float32)
    encode_opus(x32, dest, f"Eventide - {item.id}", bitrate=BITRATE, comment=COMMENT)
    for old in stale:
        if old.exists():
            old.unlink()
    if wav_dir:
        write_wav(x32, wav_dir / f"{item.id}.wav")
    # Reference for the periodicity measure: the pool simply looped (what a naive loop would do).
    naive = np.concatenate([clean[:, a:b] for a, b in pool_runs], axis=1)
    naive = np.tile(naive, (1, int(np.ceil(n / naive.shape[1]))))[:, :n]
    row = measure(item, dest, x32.astype(np.float64))
    row.update({
        "source": item.source, "source_s": round(raw.shape[1] / SR, 2),
        "rumble_suppressed_max_db": round(rumble_cut, 1), "detection": detect_info,
        "thunder_in_source_s": round(float(mask.sum()) / SR, 2),
        "pool_s": round(pool_s, 2), "pool_runs_s": [[round(a / SR, 2), round(b / SR, 2)] for a, b in pool_runs],
        "streams": item.streams, "grains": sum(len(g) for g in all_grains),
        "reuse_spacing": reuse_spacing(all_grains[0]),
        "thunder_left_source": thunder_left(raw),
        "periodicity_naive_loop": round(periodicity(naive, circular=False), 3),
        "true_peak_dbtp": round(info["true_peak_dbtp"], 2), "limited": info["limited"],
        "elapsed_s": round(time.time() - t0, 1),
    })
    return row


def measure(item: Ambiance, dest: Path, x: np.ndarray | None = None) -> dict:
    y = decode(dest)
    lufs, _ = ffmpeg_ebur128(dest)
    seam = seam_metrics(y)
    return {
        "id": item.id, "path": str(dest.relative_to(REPO)), "bytes": dest.stat().st_size,
        "seconds": item.seconds, "samples": int(round(item.seconds * SR)), "decoded_samples": int(y.shape[1]),
        "needs_end_trim": opus_needs_end_trim(dest),
        "lufs_circular": round(loudness_lufs(y), 2), "ffmpeg_lufs": lufs,
        "decoded_true_peak_dbtp": round(float(todb(true_peak(y))), 2),
        "seam_dec": {k: round(v, 4) for k, v in seam.items()},
        "seam_src_click_db": round(seam_metrics(x)["click_join_db"], 2) if x is not None else None,
        "thunder_left": thunder_left(y),
        "periodicity": round(periodicity(y, circular=True), 3),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--only", nargs="*", help="ambiance ids to (re)build")
    ap.add_argument("--check-only", action="store_true", help="re-measure the existing files")
    ap.add_argument("--wav-dir", type=Path, help="also write the float WAV masters here (not committed)")
    ap.add_argument("--report", type=Path, help="write the measurements as JSON")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    items = [i for i in ITEMS if not args.only or i.id in args.only]
    if args.only and len(items) != len(args.only):
        raise SystemExit("unknown id in --only")
    rows = []
    for item in items:
        if args.check_only:
            row = measure(item, destination(item, catalog)[0])
        else:
            row = build(item, catalog, args.wav_dir)
        rows.append(row)
        s = row["seam_dec"]
        print(f"{item.id}: {row['path']}, {row['decoded_samples'] / SR:.2f} s "
              f"({'exact' if row['decoded_samples'] == row['samples'] else 'LENGTH MISMATCH'}), "
              f"{row['bytes'] / 1024:.0f} KiB, {row['lufs_circular']} LUFS (ffmpeg {row['ffmpeg_lufs']}), "
              f"true peak {row['decoded_true_peak_dbtp']} dBTP")
        print(f"  join: step {s['join_step']:.4f} (p99 {s['step_p99']:.4f}, rank {s['step_rank_pct']:.0f} %), "
              f"click {s['click_join_db']:.1f} dB (p99 {s['click_p99_db']:.1f}, max {s['click_max_db']:.1f}, "
              f"rank {s['click_rank_pct']:.1f} %; before encoding {row['seam_src_click_db']})")
        print(f"  thunder left (100 ms level above median): {row['thunder_left']}; "
              f"periodicity {row['periodicity']}")
        if "pool_s" in row:
            print(f"  source {row['source_s']} s: thunder {row['thunder_in_source_s']} s, rumble cut up to "
                  f"{row['rumble_suppressed_max_db']} dB, pool {row['pool_s']} s {row['pool_runs_s']}; "
                  f"source thunder {row['thunder_left_source']}")
            print(f"  {row['grains']} grains in {row['streams']} stream(s), reuse of the same material "
                  f"{row['reuse_spacing']}; naive loop of the pool: periodicity {row['periodicity_naive_loop']}")
    if not args.check_only:
        manifest = write_remote_manifest()
        print(f"remote.json: sons {manifest['sons']}")
    if args.report:
        args.report.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    bad = [r["id"] for r in rows if r["decoded_samples"] != r["samples"]]
    if bad:
        print("WARNING: decoded length differs from the loop length for: " + ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
