"""Media processing (contract § 14, step 3) with ffmpeg on tiny synthetic sources (lavfi):
video loop, poster, audio loop, failures, the ``process_media`` command and its storage.

Outputs are small (108 x 192) to keep the tests fast; the pipeline is the production one.
"""

from __future__ import annotations

import io
import json
import shutil
import statistics
import subprocess
import uuid
from array import array
from io import StringIO
from pathlib import Path

import pytest
from botocore.response import StreamingBody
from botocore.stub import ANY
from django.core.management import CommandError, call_command
from django.db import connection

from apps.publishing import media, opus, processing
from apps.publishing.models import PublishedItem

State = PublishedItem.State
SMALL = media.VideoParams(width=108, height=192, preset="medium", threads=1, fade_s=1.0)
# ffmpeg is required (CI installs it, like the Docker image): no silent skip.
FFMPEG_BIN = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"
FFPROBE_BIN = shutil.which("ffprobe") or "/usr/bin/ffprobe"


def ffmpeg(*args: str) -> None:
    subprocess.run([FFMPEG_BIN, "-v", "error", "-nostdin", "-y", *args], check=True)  # noqa: S603


def raw(path: Path, *args: str) -> bytes:
    return subprocess.run(  # noqa: S603
        [FFMPEG_BIN, "-v", "error", "-i", str(path), *args], capture_output=True, check=True
    ).stdout


def ffprobe(path: Path) -> dict:
    out = subprocess.run(  # noqa: S603
        [
            FFPROBE_BIN,
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type,codec_name,profile,width,height,pix_fmt,has_b_frames,"
            "color_space,color_primaries,color_transfer:format=duration",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        check=True,
    ).stdout
    return json.loads(out)


@pytest.fixture(scope="module")
def sources(tmp_path_factory) -> dict[str, Path]:
    d = tmp_path_factory.mktemp("sources")
    s = {
        name: d / filename
        for name, filename in {
            "video": "video.mp4",
            "portrait": "portrait.mov",
            "muette": "muette.mp4",
            "piste_muette": "piste-muette.mp4",
            "courte": "courte.mp4",
            "son": "son.flac",
            "illisible": "illisible.mp4",
            "liste": "liste.mp4",
        }.items()
    }
    # Landscape video, brightness ramp (start and end very different) and its own sound.
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=9,fade=t=in:st=0:d=9",
        "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=9",
        "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.1:duration=9:sample_rate=48000",
        "-filter_complex", "[1:a][2:a]amix=inputs=2[a]",
        "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", str(s["video"]),
    )  # fmt: skip
    # Tall source (crop top and bottom), MOV, no sound.
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=180x400:rate=10:duration=9",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(s["portrait"]),
    )  # fmt: skip
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=9",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(s["muette"]),
    )  # fmt: skip
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=9",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-shortest", str(s["piste_muette"]),
    )  # fmt: skip
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=5",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-shortest", str(s["courte"]),
    )  # fmt: skip
    ffmpeg(
        "-f", "lavfi", "-i", "anoisesrc=color=brown:amplitude=0.3:duration=12:sample_rate=44100",
        "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=44100:duration=12",
        "-filter_complex", "[0:a][1:a]amix=inputs=2,aformat=channel_layouts=mono",
        "-c:a", "flac", str(s["son"]),
    )  # fmt: skip
    s["illisible"].write_bytes(bytes(range(256)) * 400)
    # An HLS playlist disguised as a video: ffmpeg must never follow it (local files only).
    s["liste"].write_text(
        "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n"
        "http://169.254.170.2/v2/credentials\n#EXT-X-ENDLIST\n"
    )
    return s


def gray_frames(path: Path, w: int = 27, h: int = 48) -> list[bytes]:
    data = raw(path, "-vf", f"scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-")
    return [data[i : i + w * h] for i in range(0, len(data), w * h)]


def mean_abs(a: bytes, b: bytes) -> float:
    return sum(abs(x - y) for x, y in zip(a, b, strict=True)) / len(a)


def rgb(path: Path, *vf: str) -> bytes:
    chain = ",".join([*vf, "format=rgb24"])
    return raw(path, "-frames:v", "1", "-vf", chain, "-f", "rawvideo", "-")


# ----------------------------------------------------------------------------
# Video
# ----------------------------------------------------------------------------


def test_landscape_video_is_a_seamless_9_16_loop(sources, tmp_path):
    info = media.probe(sources["video"])
    assert info.duration == pytest.approx(9.0, abs=0.1) and info.audio_index is not None
    result = media.make_video(sources["video"], info, tmp_path, SMALL)
    # 9 s at 12 fps = 108 frames, minus the 1 s cross-fade (12 frames).
    assert result.frames == 96 and result.seconds == 8.0 and result.fps == "12/1"
    probe = ffprobe(result.path)
    streams = probe["streams"]
    assert [s["codec_type"] for s in streams] == ["video"]  # no sound
    video = streams[0]
    assert (video["codec_name"], video["profile"], video["pix_fmt"]) == ("h264", "High", "yuv420p")
    assert (video["width"], video["height"]) == (108, 192)
    assert video["has_b_frames"] == 0
    assert video["color_space"] == "bt709" and video["color_primaries"] == "bt709"
    assert float(probe["format"]["duration"]) == pytest.approx(8.0, abs=0.1)
    # Seamless: the join (last frame -> first) is like two neighbouring frames, while the
    # source's own ends differ completely (brightness ramp).
    frames = gray_frames(result.path)
    steps = [mean_abs(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]
    join = mean_abs(frames[-1], frames[0])
    source = gray_frames(sources["video"])
    assert mean_abs(source[-1], source[0]) > 60
    assert join <= max(2.0 * statistics.median(steps), 3.0)


def test_poster_is_the_first_frame_of_the_loop(sources, tmp_path):
    result = media.make_video(sources["video"], media.probe(sources["video"]), tmp_path, SMALL)
    assert result.poster.read_bytes()[:3] == b"\xff\xd8\xff"  # JPEG
    assert result.poster_bytes == result.poster.stat().st_size <= SMALL.poster_max_bytes
    frame0 = rgb(
        result.path,
        "scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int",
    )
    poster = rgb(result.poster)
    assert len(frame0) == len(poster) == 108 * 192 * 3
    assert mean_abs(frame0, poster) < 3.0
    # ...and not another frame of the loop.
    frame5 = raw(
        result.path,
        "-vf",
        "select=eq(n\\,48),scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24",
        "-frames:v",
        "1",
        "-f",
        "rawvideo",
        "-",
    )
    assert mean_abs(frame5, poster) > mean_abs(frame0, poster) + 5


def test_crf_search_fits_the_size_limit(sources, tmp_path):
    info = media.probe(sources["video"])

    def make(name: str, max_bytes: int) -> media.VideoResult:
        workdir = tmp_path / name
        workdir.mkdir()
        params = media.VideoParams(
            width=108, height=192, preset="medium", threads=1, fade_s=1.0, max_bytes=max_bytes
        )
        return media.make_video(sources["video"], info, workdir, params)

    roomy = make("large", 500_000)
    assert roomy.crf == SMALL.crf_min and roomy.bytes <= 500_000
    tight = make("serre", 30_000)
    assert tight.bytes <= 30_000 < roomy.bytes
    assert SMALL.crf_min < tight.crf <= SMALL.crf_max
    assert tight.encodes <= SMALL.max_encodes
    with pytest.raises(media.MediaError) as excinfo:
        make("impossible", 3_000)
    assert excinfo.value.reason == media.TOO_BIG


def test_tall_source_is_cropped_and_scaled(sources, tmp_path):
    info = media.probe(sources["portrait"])
    assert info.audio_index is None
    result = media.make_video(sources["portrait"], info, tmp_path, SMALL)
    video = ffprobe(result.path)["streams"][0]
    assert (video["width"], video["height"]) == (108, 192)
    assert result.frames == 80  # 9 s at 10 fps, minus 10 frames of fade


def test_frame_rate_is_capped(tmp_path):
    src = tmp_path / "rapide.mp4"
    ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=60:duration=8.5",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(src),
    )  # fmt: skip
    result = media.make_video(src, media.probe(src), tmp_path, SMALL)
    assert result.fps == "30/1" and result.frames == 255 - 30


def test_hdr_sources_are_tone_mapped():
    stream = media.VideoStream(1, 3840, 2160, media.Fraction(30), "bt2020nc", "arib-std-b67")
    chain = media.normalise_filter(stream, SMALL, media.Fraction(30))
    assert chain.startswith("zscale=t=linear") and "tonemap=tonemap=hable" in chain
    sdr = media.VideoStream(1, 1920, 1080, media.Fraction(30), "unknown", "unknown")
    assert "in_color_matrix=bt709" in media.normalise_filter(sdr, SMALL, media.Fraction(30))


@pytest.mark.parametrize(
    ("source", "reason"),
    [
        ("courte", media.TOO_SHORT),
        ("illisible", media.UNREADABLE),
        ("liste", media.UNREADABLE),
        ("son", media.NO_VIDEO),
    ],
)
def test_unusable_video_sources(sources, tmp_path, source, reason):
    def process(path: Path) -> media.VideoResult:
        return media.make_video(path, media.probe(path), tmp_path, SMALL)

    with pytest.raises(media.MediaError) as excinfo:
        process(sources[source])
    assert excinfo.value.reason == reason


# ----------------------------------------------------------------------------
# Audio
# ----------------------------------------------------------------------------


def decode(path: Path) -> array:
    samples = array("f")
    samples.frombytes(raw(path, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"))
    return samples


def test_ambiance_is_a_gapless_loop_of_at_least_60_s(sources, tmp_path):
    out = tmp_path / "ambiance.ogg"
    result = media.make_audio(sources["video"], media.probe(sources["video"]), out, "Lac")
    assert result.samples % opus.OPUS_FRAME == 0
    assert result.seconds >= 60 and result.repeats >= 2
    data = out.read_bytes()
    assert data[:4] == b"OggS" and not opus.needs_end_trim(data)
    samples = decode(out)
    assert len(samples) // 2 == result.samples  # exactly the loop, no padding
    # The join (last sample -> first) is a step like the others around it.
    window = samples[-4800:].tolist() + samples[:4800].tolist()
    steps = [abs(window[i + 2] - window[i]) for i in range(len(window) - 2)]
    join = max(steps[4798:4800])
    others = steps[:4790] + steps[4810:]
    assert join <= 1.5 * max(others) + 1e-3
    lufs, peak = media.loudness(samples.tobytes())
    assert lufs == pytest.approx(-23.0, abs=1.0)
    assert peak <= -1.0


def test_sound_source_loop(sources, tmp_path):
    out = tmp_path / "son.ogg"
    result = media.make_audio(sources["son"], media.probe(sources["son"]), out, "Son")
    assert result.loop_seconds == pytest.approx(10.8, abs=0.1)  # 12 s - edges - 1 s fade
    assert result.repeats == 6 and result.seconds >= 60
    assert len(decode(out)) // 2 == result.samples


@pytest.mark.parametrize(
    ("source", "reason"),
    [("muette", media.NO_AUDIO), ("piste_muette", media.SILENT), ("courte", media.TOO_SHORT)],
)
def test_unusable_audio(sources, tmp_path, source, reason):
    with pytest.raises(media.MediaError) as excinfo:
        media.make_audio(sources[source], media.probe(sources[source]), tmp_path / "x.ogg", "x")
    assert excinfo.value.reason == reason


def test_gapless_remux_refuses_partial_frames():
    with pytest.raises(opus.OpusMuxError):
        opus.remux_loop(b"", 1000)
    assert opus.ogg_crc(b"OggS") == 0x5FB0A94F


# ----------------------------------------------------------------------------
# The media task: process_media <uuid>
# ----------------------------------------------------------------------------


@pytest.fixture
def local_storage(settings, tmp_path, monkeypatch):
    root = tmp_path / "stockage"
    root.mkdir()
    settings.MEDIA_STORAGE = f"local:{root}"
    monkeypatch.setattr(processing, "VIDEO_PARAMS", SMALL)
    return root


def element(kind: str, item_id: str, root: Path | None, source: Path | None, **fields):
    upload_id = uuid.uuid4()
    if root is not None and source is not None:
        target = root / "uploads" / str(upload_id) / "source"
        target.parent.mkdir(parents=True)
        target.write_bytes(source.read_bytes())
    defaults = {"state": State.TRAITEMENT, "upload_id": upload_id, "pending_rev": 1}
    defaults.update(fields)
    return PublishedItem.objects.create(kind=kind, item_id=item_id, nom="Essai", **defaults)


def run(item: PublishedItem) -> dict:
    out = StringIO()
    call_command("process_media", str(item.pk), stdout=out)
    item.refresh_from_db()
    return json.loads(out.getvalue())


@pytest.mark.django_db(transaction=True)
def test_process_a_landscape(sources, local_storage):
    item = element("paysage", "lac-brume", local_storage, sources["video"], pending_rev=3)
    assert run(item) == {"event": "process_media_done", "state": "pret"}
    assert item.state == State.PRET and item.pending_has_ambiance and item.detail == ""
    for key in (
        "videos/paysages/lac-brume.v3.mp4",
        "images/paysages/lac-brume.v3.jpg",
        "audio/sons/ambiance-lac-brume.v3.ogg",
    ):
        assert (local_storage / key).is_file(), key
    assert item.pending_info["video"]["secondes"] == 8.0
    assert item.pending_info["ambiance"]["secondes"] >= 60
    # Idempotent: a second run has nothing to do and rewrites nothing.
    mtime = (local_storage / "videos/paysages/lac-brume.v3.mp4").stat().st_mtime_ns
    assert run(item)["state"] == "pret"
    assert (local_storage / "videos/paysages/lac-brume.v3.mp4").stat().st_mtime_ns == mtime


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize("source", ["muette", "piste_muette"])
def test_a_silent_video_makes_a_landscape_without_ambiance(sources, local_storage, source):
    item = element("paysage", "desert", local_storage, sources[source])
    assert run(item)["state"] == "pret"
    assert not item.pending_has_ambiance
    assert item.detail == processing.SILENT_LANDSCAPE
    assert (local_storage / "videos/paysages/desert.v1.mp4").is_file()
    assert not (local_storage / "audio/sons/ambiance-desert.v1.ogg").exists()


@pytest.mark.django_db(transaction=True)
def test_a_soundtrack_failure_keeps_the_landscape(sources, local_storage, monkeypatch):
    def broken(*args, **kwargs):
        raise media.MediaError(media.ENCODING_FAILED)

    monkeypatch.setattr(media, "make_audio", broken)
    item = element("paysage", "desert", local_storage, sources["video"])
    assert run(item)["state"] == "pret"
    assert not item.pending_has_ambiance
    assert item.detail == processing.UNUSABLE_SOUNDTRACK


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(("kind", "folder"), [("son", "sons"), ("musique", "musiques")])
def test_process_a_sound_or_music(sources, local_storage, kind, folder):
    item = element(kind, "riviere", local_storage, sources["son"], pending_rev=2)
    assert run(item)["state"] == "pret"
    assert (local_storage / f"audio/{folder}/riviere.v2.ogg").is_file()
    assert item.pending_info["audio"]["secondes"] >= 60


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(
    ("kind", "source", "reason"),
    [
        ("paysage", "courte", media.TOO_SHORT),
        ("paysage", "illisible", media.UNREADABLE),
        ("paysage", "liste", media.UNREADABLE),
        ("paysage", "son", media.NO_VIDEO),
        ("son", "muette", media.NO_AUDIO),
        ("musique", "piste_muette", media.SILENT),
        ("son", None, processing.SOURCE_MISSING),
    ],
)
def test_failures_are_recorded_with_their_reason(sources, local_storage, kind, source, reason):
    item = element(kind, "essai", local_storage, sources[source] if source else None)
    assert run(item)["state"] == "echec"
    assert item.detail == reason
    assert not any(local_storage.glob("videos/**/*")) and not any(local_storage.glob("audio/**/*"))


@pytest.mark.django_db(transaction=True)
def test_storage_not_configured(sources, settings):
    settings.MEDIA_STORAGE = ""
    item = element("son", "essai", None, None)
    assert run(item)["state"] == "echec"
    assert item.detail == processing.NOT_CONFIGURED


@pytest.mark.django_db(transaction=True)
def test_nothing_to_do_outside_processing(local_storage):
    item = element("son", "essai", None, None, state=State.PUBLIE)
    assert run(item)["state"] == "publie"
    with pytest.raises(CommandError):
        call_command("process_media", "pas-un-uuid")
    missing = str(uuid.uuid4())
    out = StringIO()
    call_command("process_media", missing, stdout=out)
    assert json.loads(out.getvalue())["state"] == "absent"


@pytest.mark.django_db(transaction=True)
def test_no_database_connection_during_the_work(sources, local_storage, monkeypatch):
    seen = []
    real = media.make_audio

    def spy(*args, **kwargs):
        seen.append(connection.connection is None)
        return real(*args, **kwargs)

    monkeypatch.setattr(media, "make_audio", spy)
    item = element("son", "riviere", local_storage, sources["son"])
    assert run(item)["state"] == "pret"
    assert seen == [True]


@pytest.mark.django_db(transaction=True)
def test_a_newer_upload_wins_over_a_finishing_task(sources, local_storage, monkeypatch):
    real = processing.run_job

    def replaced_meanwhile(job, store, workdir):
        outcome = real(job, store, workdir)
        PublishedItem.objects.filter(pk=job.element_id).update(
            upload_id=uuid.uuid4(), state=State.ENVOI, pending_rev=2
        )
        return outcome

    monkeypatch.setattr(processing, "run_job", replaced_meanwhile)
    item = element("son", "riviere", local_storage, sources["son"])
    assert run(item)["state"] == "envoi"
    assert item.pending_rev == 2


@pytest.mark.django_db(transaction=True)
def test_s3_storage_reads_the_source_and_writes_versioned_keys(
    sources, settings, aws_stubs, monkeypatch
):
    settings.MEDIA_STORAGE = "s3"
    item = element("son", "riviere", None, None, pending_rev=4)
    body = sources["son"].read_bytes()
    stubber = aws_stubs("s3")
    stubber.add_response(
        "get_object",
        {"Body": StreamingBody(io.BytesIO(body), len(body)), "ContentLength": len(body)},
        {"Bucket": "ev-test-content", "Key": f"uploads/{item.upload_id}/source"},
    )
    stubber.add_response(
        "put_object",
        {"ETag": '"x"'},
        {
            "Bucket": "ev-test-content",
            "Key": "audio/sons/riviere.v4.ogg",
            "Body": ANY,
            "ContentType": "audio/ogg",
            "CacheControl": "public, max-age=31536000, immutable",
        },
    )
    assert run(item)["state"] == "pret"
    stubber.assert_no_pending_responses()


@pytest.mark.django_db(transaction=True)
@pytest.mark.parametrize(
    ("code", "status"),
    # Without s3:ListBucket (media role), a missing key answers 403 AccessDenied.
    [("AccessDenied", 403), ("NoSuchKey", 404)],
)
def test_s3_source_missing(settings, aws_stubs, code, status):
    settings.MEDIA_STORAGE = "s3"
    item = element("son", "riviere", None, None)
    aws_stubs("s3").add_client_error("get_object", service_error_code=code, http_status_code=status)
    assert run(item)["state"] == "echec"  # handled: exit code 0
    assert item.detail == processing.SOURCE_MISSING


@pytest.mark.django_db(transaction=True)
def test_an_unexpected_error_is_recorded_and_exits_non_zero(local_storage, monkeypatch):
    def bug(job, store, workdir):
        raise RuntimeError("bug")

    monkeypatch.setattr(processing, "run_job", bug)
    item = element("son", "riviere", None, None)
    out = StringIO()
    with pytest.raises(CommandError):
        call_command("process_media", str(item.pk), stdout=out)
    assert json.loads(out.getvalue()) == {"event": "process_media_crashed", "state": "echec"}
    item.refresh_from_db()
    assert item.state == State.ECHEC and item.detail == processing.INTERNAL


@pytest.mark.django_db(transaction=True)
def test_s3_source_too_large(settings, aws_stubs):
    settings.MEDIA_STORAGE = "s3"
    settings.UPLOAD_MAX_BYTES = 10
    item = element("son", "riviere", None, None)
    aws_stubs("s3").add_response(
        "get_object",
        {"Body": StreamingBody(io.BytesIO(b"x" * 20), 20), "ContentLength": 20},
    )
    assert run(item)["state"] == "echec"
    assert item.detail == processing.SOURCE_TOO_LARGE
