"""Media processing for the dashboard (contract § 14), with ffmpeg and ffprobe only.

Generic: no per-item tuning. The parameters are those of the proven tools of ``tools/media/``
(``process_video.py``, ``make_ambiance.py``, ``generate_audio.py``), reimplemented here
without numpy.

Landscape video (``process_video.py``):
  * centre crop to 9:16, scaled to 1080 x 1920 (cover), BT.709, constant frame rate (the
    source's, at most 30 fps); at most 10 s of loop (+ the fade) are used;
  * **seamless loop**: the last F frames (1.5 s) are cross-faded over the first F frames, so
    the loop has N - F frames and its last frame flows into its first as two consecutive
    source frames do. The loop is written starting at source frame F (a rotation of the same
    cycle): only those F head frames are held in memory while the rest streams through;
  * H.264 High, yuv420p, no B-frames, a key frame every 2 s, ``+faststart``, no audio, no
    metadata; the lowest CRF in [18, 36] that keeps the file under 2.5 MB (searched with a
    rate model: the size halves every +6 CRF);
  * poster: the encoded loop's own first frame, decoded back, JPEG of 300 KB at most.

Audio loop (``make_ambiance.py``, ``generate_audio.py``):
  * first audio stream, 48 kHz stereo float, 0.1 s dropped at each edge, 22 Hz high-pass,
    at most 3 minutes of source;
  * **seamless loop**: the last 1 s cross-faded over the first 1 s with equal-power (sine /
    cosine) curves, a whole number of 20 ms Opus frames, repeated to last at least 60 s;
  * loudness -23 LUFS (EBU R128), true peak <= -1 dBTP: the gain is lowered rather than
    limited (no limiter state across the join);
  * Ogg Opus 96 kbit/s (recorded nature sounds are dense noise), gapless (``opus.py``).

Resources (1 vCPU / 2 GB Fargate task, shared vCPU budget of the account): x264 and decoders
run with 2 threads, filters with 1; the lossless intermediate files live on disk (``/tmp``).

Media files are untrusted input: they are only read through ffmpeg/ffprobe, restricted to the
local file protocol and to the expected demuxers (no playlist, no network or file reference).
"""

from __future__ import annotations

import json
import logging
import math
import re
import shutil
import subprocess  # nosec B404 - ffmpeg/ffprobe with argument lists, never a shell
import sys
from array import array
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

from . import opus

logger = logging.getLogger(__name__)

SAMPLE_RATE = opus.SAMPLE_RATE
FRAME_BYTES = 8  # interleaved float32 stereo
MIN_SOURCE_S = 8.0
STEP_TIMEOUT_S = 20 * 60
# Untrusted sources: local file only, expected container formats only (MP4/MOV/M4A, MKV/WebM,
# WAV, MP3, OGG, FLAC). An HLS or concat playlist disguised as a video is refused.
SOURCE_INPUT_OPTIONS = (
    "-protocol_whitelist",
    "file",
    "-format_whitelist",
    "mov,matroska,wav,mp3,ogg,flac",
)
HDR_TRANSFERS = ("smpte2084", "arib-std-b67")

# Short French reasons shown in the dashboard (contract § 14: « état echec avec la raison »).
UNREADABLE = "Fichier illisible : format non reconnu ou fichier abîmé."
TOO_SHORT = "Source trop courte : il faut au moins 8 secondes."
NO_VIDEO = "Aucune image dans ce fichier : il faut une vidéo."
NO_AUDIO = "Aucun son dans ce fichier."
SILENT = "Le son du fichier est muet."
TOO_BIG = "La vidéo dépasse 2,5 Mo même à la qualité la plus basse."
POSTER_TOO_BIG = "L'image fixe dépasse 300 Ko."
TOO_LONG = "Traitement trop long : essayez un fichier plus court."
TOOL_MISSING = "Outil de traitement absent du serveur (ffmpeg)."
ENCODING_FAILED = "Le traitement du fichier a échoué."


class MediaError(Exception):
    """A processing failure; ``reason`` is the short French text shown in the dashboard."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class NoUsableAudio(MediaError):
    """No audio stream, a silent one, or one too short: a landscape is then published without
    ambiance (contract § 14)."""


@dataclass(frozen=True)
class VideoParams:
    width: int = 1080
    height: int = 1920
    max_fps: int = 30
    fade_s: float = 1.5
    # 2.5 MB at 1080 x 1920 binds the quality: the base loops last 5.9 to 7.6 s (CRF 18-24 at
    # 720 x 1280). 10 s keeps the repetition long enough for a CRF around 30 on real footage.
    max_loop_s: float = 10.0
    max_bytes: int = 2_500_000
    crf_min: int = 18
    crf_max: int = 36
    crf_first: int = 26
    max_encodes: int = 6
    # ``medium``: a 20 s 1080p source takes about 2.5 min on one vCPU (``slow`` doubles it).
    preset: str = "medium"
    threads: int = 2
    gop_s: int = 2
    level: str = "4.0"
    poster_max_bytes: int = 300_000


@dataclass(frozen=True)
class AudioParams:
    fade_s: float = 1.0
    min_loop_s: float = 60.0
    max_source_s: float = 180.0
    edge_trim_s: float = 0.1
    target_lufs: float = -23.0
    true_peak_max_db: float = -1.0
    # When the loudness gain would push the true peak over the ceiling, the gain stops this far
    # below it (Opus encoding moves peaks a little).
    peak_margin_db: float = 0.5
    silence_lufs: float = -60.0
    bitrate: str = "96k"


@dataclass(frozen=True)
class VideoStream:
    index: int
    width: int
    height: int
    rate: Fraction
    space: str
    transfer: str


@dataclass(frozen=True)
class Probe:
    duration: float
    video: VideoStream | None
    audio_index: int | None


@dataclass(frozen=True)
class VideoResult:
    path: Path
    poster: Path
    frames: int
    fps: str
    seconds: float
    bytes: int
    crf: int
    encodes: int
    poster_bytes: int


@dataclass(frozen=True)
class AudioResult:
    path: Path
    samples: int
    seconds: float
    loop_seconds: float
    repeats: int
    bytes: int
    gain_db: float
    lufs: float | None
    true_peak_db: float | None


# ----------------------------------------------------------------------------
# ffmpeg helpers
# ----------------------------------------------------------------------------


def _tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise MediaError(TOOL_MISSING)
    return path


def _run(
    cmd: list[str],
    *,
    step: str,
    reason: str = ENCODING_FAILED,
    stdin: bytes | None = None,
    timeout: float = STEP_TIMEOUT_S,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(  # noqa: S603  # nosec B603 - argument list, no shell
            cmd, input=stdin, capture_output=True, timeout=timeout, check=True
        )
    except FileNotFoundError as exc:
        raise MediaError(TOOL_MISSING) from exc
    except subprocess.TimeoutExpired as exc:
        raise MediaError(TOO_LONG) from exc
    except subprocess.CalledProcessError as exc:
        tail = exc.stderr.decode("utf-8", "replace")[-400:] if exc.stderr else ""
        logger.warning(
            "Media step failed", extra={"event": "media_step_failed", "step": step, "tail": tail}
        )
        raise MediaError(reason) from exc


def _rate(stream: dict) -> Fraction:
    for key in ("avg_frame_rate", "r_frame_rate"):
        try:
            value = Fraction(stream.get(key, "0/0"))
        except (ValueError, ZeroDivisionError):
            continue
        if value > 0:
            return value
    return Fraction(0)


def probe(path: Path) -> Probe:
    """Duration and streams of an untrusted source (``MediaError`` if unreadable)."""
    out = _run(
        [
            _tool("ffprobe"),
            "-v",
            "error",
            *SOURCE_INPUT_OPTIONS,
            "-show_entries",
            "format=duration:stream=index,codec_type,width,height,avg_frame_rate,"
            "r_frame_rate,color_space,color_transfer,duration:stream_disposition=attached_pic",
            "-of",
            "json",
            str(path),
        ],
        step="probe",
        reason=UNREADABLE,
        timeout=120,
    ).stdout
    try:
        data = json.loads(out)
    except ValueError as exc:
        raise MediaError(UNREADABLE) from exc
    streams = data.get("streams") or []
    durations = []
    for value in [(data.get("format") or {}).get("duration")] + [
        s.get("duration") for s in streams
    ]:
        try:
            seconds = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(seconds) and seconds > 0:
            durations.append(seconds)
    if not durations:
        raise MediaError(UNREADABLE)
    video = None
    audio_index = None
    for s in streams:
        kind = s.get("codec_type")
        if kind == "video" and video is None and not s.get("disposition", {}).get("attached_pic"):
            try:
                width, height = int(s["width"]), int(s["height"])
            except (KeyError, TypeError, ValueError):
                continue
            if width > 0 and height > 0:
                video = VideoStream(
                    index=int(s["index"]),
                    width=width,
                    height=height,
                    rate=_rate(s),
                    space=str(s.get("color_space", "unknown")),
                    transfer=str(s.get("color_transfer", "unknown")),
                )
        elif kind == "audio" and audio_index is None:
            audio_index = int(s["index"])
    return Probe(duration=durations[0], video=video, audio_index=audio_index)


def count_frames(path: Path) -> int:
    out = _run(
        [
            _tool("ffprobe"),
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-count_packets",
            "-show_entries",
            "stream=nb_read_packets",
            "-of",
            "csv=p=0",
            str(path),
        ],
        step="count",
    ).stdout
    try:
        return int(out.decode().strip().split(",")[0])
    except (ValueError, IndexError) as exc:
        raise MediaError(ENCODING_FAILED) from exc


# ----------------------------------------------------------------------------
# Landscape video
# ----------------------------------------------------------------------------


def target_rate(stream: VideoStream, params: VideoParams) -> Fraction:
    """The source frame rate (rationals such as 30000/1001 kept), at most ``max_fps``."""
    rate = stream.rate.limit_denominator(1001) if stream.rate > 0 else Fraction(params.max_fps)
    return min(rate, Fraction(params.max_fps))


def _input_matrix(stream: VideoStream) -> str:
    if stream.space == "bt709":
        return "bt709"
    if stream.space in ("bt470bg", "smpte170m", "bt601"):
        return "bt601"
    if stream.space.startswith("bt2020"):
        return "bt2020"
    # Untagged: what players assume (BT.709 for HD, BT.601 for SD).
    return "bt709" if stream.height >= 720 or stream.width >= 1280 else "bt601"


def normalise_filter(stream: VideoStream, params: VideoParams, rate: Fraction) -> str:
    """Cover crop to the output aspect, scale, BT.709 limited range, constant frame rate."""
    w, h = params.width, params.height
    chain = []
    if stream.transfer in HDR_TRANSFERS:
        # HDR (HLG or PQ phone videos): tone-mapped to SDR BT.709.
        chain.append(
            "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
            "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
        )
        matrix = "bt709"
    else:
        matrix = _input_matrix(stream)
    chain += [
        f"crop='trunc(min(iw,ih*{w}/{h})/2)*2':'trunc(min(ih,iw*{h}/{w})/2)*2'",
        f"scale={w}:{h}:flags=bicubic:in_color_matrix={matrix}:out_color_matrix=bt709:out_range=tv",
        "setsar=1",
        f"fps={rate.numerator}/{rate.denominator}",
        "format=yuv420p",
    ]
    return ",".join(chain)


def loop_filter(frames: int, fade: int) -> str:
    """Seamless loop of ``frames`` frames: ``frames - fade`` frames out, starting at source
    frame ``fade``; the last ``fade`` frames cross-fade the source tail (frames L..N-1) into
    its head (frames 0..F-1), weight of the head (j+1)/(F+1) at frame j."""
    loop = frames - fade
    return (
        "[0:v]split=2[a][b];"
        f"[a]trim=start_frame={fade}:end_frame={loop},setpts=PTS-STARTPTS[mid];"
        "[b]split=2[h][t];"
        f"[h]trim=end_frame={fade},setpts=PTS-STARTPTS[head];"
        f"[t]trim=start_frame={loop}:end_frame={frames},setpts=PTS-STARTPTS[tail];"
        f"[tail][head]blend=all_expr='A+(B-A)*(N+1)/{fade + 1}+0.5':shortest=1[x];"
        "[mid][x]concat=n=2:v=1:a=0[out]"
    )


def _lossless(path: Path, threads: int) -> list[str]:
    return [
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-qp",
        "0",
        "-pix_fmt",
        "yuv420p",
        "-threads",
        str(threads),
        "-f",
        "matroska",
        str(path),
    ]


def _encode(src: Path, out: Path, crf: int, rate: Fraction, params: VideoParams) -> int:
    gop = max(1, round(params.gop_s * rate))
    _run(
        [
            _tool("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-threads",
            str(params.threads),
            "-i",
            str(src),
            "-map",
            "0:v:0",
            "-an",
            "-sn",
            "-dn",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-c:v",
            "libx264",
            "-preset",
            params.preset,
            "-crf",
            str(crf),
            "-profile:v",
            "high",
            "-level:v",
            params.level,
            "-pix_fmt",
            "yuv420p",
            "-bf",
            "0",
            "-threads",
            str(params.threads),
            "-x264-params",
            f"keyint={gop}:min-keyint={gop}:scenecut=0:bframes=0:open-gop=0",
            "-color_range",
            "tv",
            "-colorspace",
            "bt709",
            "-color_primaries",
            "bt709",
            "-color_trc",
            "bt709",
            "-movflags",
            "+faststart",
            "-fflags",
            "+bitexact",
            "-flags:v",
            "+bitexact",
            "-metadata:s:v:0",
            "handler_name=Eventide landscape",
            "-metadata:s:v:0",
            "language=und",
            "-f",
            "mp4",
            str(out),
        ],
        step="encode",
    )
    return out.stat().st_size


def encode_under_budget(
    src: Path, workdir: Path, rate: Fraction, params: VideoParams
) -> tuple[Path, int, int, int]:
    """Lowest CRF whose file fits in ``params.max_bytes``: (file, crf, size, encodes)."""
    lo, hi = params.crf_min, params.crf_max
    crf = min(max(params.crf_first, lo), hi)
    best: tuple[int, int] | None = None
    encodes = 0
    while lo <= hi and encodes < params.max_encodes:
        size = _encode(src, workdir / f"try-{crf}.mp4", crf, rate, params)
        encodes += 1
        if size <= params.max_bytes:
            best = (crf, size)
            hi = crf - 1
        else:
            lo = crf + 1
        if lo > hi:
            break
        # Rate model: the size halves every +6 CRF. Aim just under the budget.
        step = 6 * math.log2(size / (params.max_bytes * 0.97))
        guess = crf + (math.ceil(step) if step > 0 else math.floor(step))
        crf = min(max(guess, lo), hi)
    if best is None:
        if lo <= params.crf_max and encodes >= params.max_encodes:
            # Out of attempts: the lowest quality is the last resort.
            size = _encode(src, workdir / "try-max.mp4", params.crf_max, rate, params)
            encodes += 1
            if size <= params.max_bytes:
                return workdir / "try-max.mp4", params.crf_max, size, encodes
        raise MediaError(TOO_BIG)
    return workdir / f"try-{best[0]}.mp4", best[0], best[1], encodes


def write_poster(video: Path, poster: Path, max_bytes: int) -> int:
    """The video's own first frame as a JPEG (JFIF: BT.601 full range), quality lowered until
    it fits in ``max_bytes``."""
    for quality in (3, 4, 5, 6, 8, 10, 13, 16, 20, 25, 31):
        _run(
            [
                _tool("ffmpeg"),
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-i",
                str(video),
                "-map",
                "0:v:0",
                "-frames:v",
                "1",
                "-vf",
                "scale=in_color_matrix=bt709:in_range=tv:out_color_matrix=bt601:out_range=pc"
                ":flags=bicubic+accurate_rnd+full_chroma_int,format=yuvj420p",
                "-q:v",
                str(quality),
                "-map_metadata",
                "-1",
                "-f",
                "image2",
                "-update",
                "1",
                str(poster),
            ],
            step="poster",
        )
        size = poster.stat().st_size
        if size <= max_bytes:
            return size
    raise MediaError(POSTER_TOO_BIG)


def make_video(
    src: Path, info: Probe, workdir: Path, params: VideoParams | None = None
) -> VideoResult:
    params = params or VideoParams()
    if info.video is None:
        raise MediaError(NO_VIDEO)
    if info.duration < MIN_SOURCE_S:
        raise MediaError(TOO_SHORT)
    stream = info.video
    rate = target_rate(stream, params)
    use_s = min(info.duration, params.max_loop_s + params.fade_s)
    ffmpeg = _tool("ffmpeg")
    normalised = workdir / "normalise.mkv"
    _run(
        [
            ffmpeg,
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-filter_threads",
            "1",
            "-threads",
            str(params.threads),
            *SOURCE_INPUT_OPTIONS,
            "-i",
            str(src),
            "-map",
            f"0:{stream.index}",
            "-an",
            "-sn",
            "-dn",
            "-t",
            f"{use_s:.3f}",
            "-vf",
            normalise_filter(stream, params, rate),
            *_lossless(normalised, params.threads),
        ],
        step="normalise",
        reason=UNREADABLE,
    )
    frames = count_frames(normalised)
    fade = max(1, round(params.fade_s * rate))
    if frames < 3 * fade or frames / rate < MIN_SOURCE_S - 0.5:
        raise MediaError(TOO_SHORT)
    looped = workdir / "boucle.mkv"
    _run(
        [
            ffmpeg,
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-filter_complex_threads",
            "1",
            "-i",
            str(normalised),
            "-filter_complex",
            loop_filter(frames, fade),
            "-map",
            "[out]",
            *_lossless(looped, params.threads),
        ],
        step="loop",
    )
    normalised.unlink(missing_ok=True)
    out_frames = count_frames(looped)
    if out_frames != frames - fade:
        logger.warning(
            "Unexpected loop length",
            extra={"event": "media_loop_length", "expected": frames - fade, "got": out_frames},
        )
        raise MediaError(ENCODING_FAILED)
    video, crf, size, encodes = encode_under_budget(looped, workdir, rate, params)
    looped.unlink(missing_ok=True)
    final = workdir / "video.mp4"
    video.replace(final)
    for leftover in workdir.glob("try-*.mp4"):
        leftover.unlink(missing_ok=True)
    poster = workdir / "poster.jpg"
    poster_bytes = write_poster(final, poster, params.poster_max_bytes)
    return VideoResult(
        path=final,
        poster=poster,
        frames=out_frames,
        fps=f"{rate.numerator}/{rate.denominator}",
        seconds=round(out_frames / float(rate), 3),
        bytes=size,
        crf=crf,
        encodes=encodes,
        poster_bytes=poster_bytes,
    )


# ----------------------------------------------------------------------------
# Audio loops (landscape ambiance, sound, music)
# ----------------------------------------------------------------------------

_LUFS_RE = re.compile(r"I:\s+(-?[\d.]+|-inf) LUFS")
_PEAK_RE = re.compile(r"Peak:\s+(-?[\d.]+|-inf) dBFS")


def _floats(raw: bytes) -> array:
    values = array("f")
    values.frombytes(raw)
    if sys.byteorder != "little":  # f32le from ffmpeg
        values.byteswap()
    return values


def _to_bytes(values: array) -> bytes:
    if sys.byteorder != "little":
        values = array("f", values)
        values.byteswap()
    return values.tobytes()


def loudness(pcm: bytes) -> tuple[float | None, float | None]:
    """Integrated loudness (LUFS) and true peak (dBTP) of float32 stereo 48 kHz PCM; None for
    silence (-inf)."""
    res = _run(
        [
            _tool("ffmpeg"),
            "-nostdin",
            "-hide_banner",
            "-nostats",
            "-f",
            "f32le",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "2",
            "-i",
            "pipe:0",
            "-af",
            "ebur128=peak=true:framelog=quiet",
            "-f",
            "null",
            "-",
        ],
        step="loudness",
        stdin=pcm,
    )
    text = res.stderr.decode("utf-8", "replace")
    summary = text[text.rfind("Summary:") :]
    lufs = _LUFS_RE.search(summary)
    peak = _PEAK_RE.search(summary)

    def value(match: re.Match | None) -> float | None:
        if match is None or match.group(1) == "-inf":
            return None
        return float(match.group(1))

    return value(lufs), value(peak)


def decode_audio(src: Path, stream_index: int, params: AudioParams) -> bytes:
    """First ``max_source_s`` seconds of an audio stream as float32 stereo 48 kHz PCM, edges
    dropped, 22 Hz high-pass (DC and rumble guard)."""
    edge = round(params.edge_trim_s * SAMPLE_RATE) * FRAME_BYTES
    raw = _run(
        [
            _tool("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-threads",
            "2",
            *SOURCE_INPUT_OPTIONS,
            "-i",
            str(src),
            "-map",
            f"0:{stream_index}",
            "-vn",
            "-sn",
            "-dn",
            "-t",
            f"{params.max_source_s + 2 * params.edge_trim_s:.3f}",
            "-af",
            "highpass=f=22",
            "-ac",
            "2",
            "-ar",
            str(SAMPLE_RATE),
            "-c:a",
            "pcm_f32le",
            "-f",
            "f32le",
            "pipe:1",
        ],
        step="decode_audio",
        reason=UNREADABLE,
    ).stdout
    usable = len(raw) - len(raw) % FRAME_BYTES
    return raw[edge : max(edge, usable - edge)]


def build_loop(pcm: bytes, params: AudioParams) -> tuple[bytes, int]:
    """One seamless loop (``pcm`` frames F..L-1, then the tail L..L+F-1 cross-faded into the
    head 0..F-1, equal power), L a whole number of Opus frames: (loop bytes, L)."""
    n = len(pcm) // FRAME_BYTES
    fade = round(params.fade_s * SAMPLE_RATE)
    loop = ((n - fade) // opus.OPUS_FRAME) * opus.OPUS_FRAME
    if loop < max(2 * fade, round((MIN_SOURCE_S - 1.5) * SAMPLE_RATE)):
        raise NoUsableAudio(TOO_SHORT)
    head = _floats(pcm[: fade * FRAME_BYTES])
    tail = _floats(pcm[loop * FRAME_BYTES : (loop + fade) * FRAME_BYTES])
    fade_in = [math.sin(0.5 * math.pi * (j + 0.5) / fade) for j in range(fade)]
    mixed = array("f", bytes(fade * FRAME_BYTES))
    for j in range(fade):
        gain_in, gain_out = fade_in[j], fade_in[fade - 1 - j]
        a = 2 * j
        mixed[a] = tail[a] * gain_out + head[a] * gain_in
        mixed[a + 1] = tail[a + 1] * gain_out + head[a + 1] * gain_in
    return pcm[fade * FRAME_BYTES : loop * FRAME_BYTES] + _to_bytes(mixed), loop


def decoded_samples(path: Path) -> int:
    """Samples a reference decoder outputs (pre-skip and end trim honoured)."""
    raw = _run(
        [
            _tool("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-i",
            str(path),
            "-f",
            "f32le",
            "-ac",
            "2",
            "-ar",
            str(SAMPLE_RATE),
            "pipe:1",
        ],
        step="verify_audio",
    ).stdout
    return len(raw) // FRAME_BYTES


def make_audio(
    src: Path,
    info: Probe,
    out: Path,
    title: str,
    params: AudioParams | None = None,
) -> AudioResult:
    """Seamless Ogg Opus loop of at least ``min_loop_s`` from the source's first audio stream.
    ``NoUsableAudio`` when it has none, a silent one, or one too short."""
    params = params or AudioParams()
    if info.audio_index is None:
        raise NoUsableAudio(NO_AUDIO)
    if info.duration < MIN_SOURCE_S:
        raise MediaError(TOO_SHORT)
    pcm = decode_audio(src, info.audio_index, params)
    loop, length = build_loop(pcm, params)
    del pcm
    lufs, peak = loudness(loop)
    if lufs is None or lufs <= params.silence_lufs or peak is None:
        raise NoUsableAudio(SILENT)
    gain = params.target_lufs - lufs
    ceiling = params.true_peak_max_db - params.peak_margin_db
    if peak + gain > ceiling:
        gain = ceiling - peak
    repeats = math.ceil(params.min_loop_s * SAMPLE_RATE / length)
    full = loop * repeats
    samples = length * repeats
    del loop
    try:
        extended = opus.circular_extension(full, FRAME_BYTES)
    except opus.OpusMuxError as exc:
        raise MediaError(ENCODING_FAILED) from exc
    del full
    encoded = _run(
        [
            _tool("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-f",
            "f32le",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "2",
            "-i",
            "pipe:0",
            "-af",
            f"volume={gain:.3f}dB",
            "-c:a",
            "libopus",
            "-b:a",
            params.bitrate,
            "-vbr",
            "on",
            "-application",
            "audio",
            "-frame_duration",
            "20",
            "-map_metadata",
            "-1",
            "-metadata",
            f"title={title}",
            "-fflags",
            "+bitexact",
            "-flags:a",
            "+bitexact",
            "-f",
            "ogg",
            "pipe:1",
        ],
        step="encode_audio",
        stdin=extended,
    ).stdout
    del extended
    try:
        data = opus.remux_loop(encoded, samples)
    except opus.OpusMuxError as exc:
        logger.warning("Opus remux failed", extra={"event": "media_opus_remux", "why": str(exc)})
        raise MediaError(ENCODING_FAILED) from exc
    out.write_bytes(data)
    if decoded_samples(out) != samples:
        raise MediaError(ENCODING_FAILED)
    return AudioResult(
        path=out,
        samples=samples,
        seconds=round(samples / SAMPLE_RATE, 3),
        loop_seconds=round(length / SAMPLE_RATE, 3),
        repeats=repeats,
        bytes=len(data),
        gain_db=round(gain, 2),
        lufs=round(lufs + gain, 1),
        true_peak_db=round(peak + gain, 1),
    )
