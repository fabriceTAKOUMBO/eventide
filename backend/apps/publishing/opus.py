"""Gapless Ogg Opus loops (same method as ``tools/media/generate_audio.encode_opus``, without
numpy): a loop of N samples (a whole number of 20 ms frames) decodes to exactly N samples and
its last sample flows into its first.

Plain ffmpeg output starts the encoder from silence and pads the end: both edges are coded as
transients, and a player that ignores the end-trim granule plays a few ms of padding before
looping. So:

1. the circular extension ``[loop tail | loop | loop head]`` is encoded, so that the first and
   last frames of the loop are coded with real context on both sides;
2. only the packets covering exactly the loop are kept;
3. copies of the loop's own last packets are prepended as warm-up, and the OpusHead pre-skip
   is set to their length: the decoder discards them but enters sample 0 in (almost) the state
   it leaves sample N-1;
4. the packets are muxed again with granules that match their total: no end trim needed.
"""

from __future__ import annotations

SAMPLE_RATE = 48_000
OPUS_FRAME = 960  # 20 ms packets
OPUS_ENCODER_DELAY = 312  # libopus look-ahead at 48 kHz (pre-skip of the OpusHead it writes)
PREROLL_FRAMES = 16  # 320 ms of loop tail encoded before sample 0 (encoder state settles)
POSTROLL_FRAMES = 4  # 80 ms of loop head encoded after the last sample, then dropped
WARMUP_FRAMES = 16  # copies of the loop's last packets decoded (and skipped) before sample 0


class OpusMuxError(Exception):
    pass


def _crc_table() -> tuple[int, ...]:
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else r << 1
        table.append(r & 0xFFFFFFFF)
    return tuple(table)


_OGG_CRC = _crc_table()


def ogg_crc(data: bytes | bytearray) -> int:
    crc = 0
    table = _OGG_CRC
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[((crc >> 24) & 0xFF) ^ b]
    return crc


def ogg_packets(data: bytes) -> tuple[int, list[bytes], int]:
    """Split a single-stream Ogg file into (serial, packets, last granule)."""
    pos, packets, partial, serial, granule = 0, [], b"", 0, 0
    while pos < len(data):
        if data[pos : pos + 4] != b"OggS":
            raise OpusMuxError("not an Ogg page")
        granule = int.from_bytes(data[pos + 6 : pos + 14], "little", signed=True)
        serial = int.from_bytes(data[pos + 14 : pos + 18], "little")
        nseg = data[pos + 26]
        body = pos + 27 + nseg
        for lv in data[pos + 27 : pos + 27 + nseg]:
            partial += data[body : body + lv]
            body += lv
            if lv < 255:
                packets.append(partial)
                partial = b""
        pos = body
    return serial, packets, granule


def opus_packet_samples(packet: bytes) -> int:
    """Duration of an Opus packet in 48 kHz samples (RFC 6716 TOC byte)."""
    config, code = packet[0] >> 3, packet[0] & 3
    if config < 12:
        size = (480, 960, 1920, 2880)[config & 3]
    elif config < 16:
        size = (480, 960)[config & 1]
    else:
        size = (120, 240, 480, 960)[config & 3]
    frames = 1 if code == 0 else 2 if code in (1, 2) else packet[1] & 0x3F
    return size * frames


def ogg_write(serial: int, head: bytes, tags: bytes, audio: list[bytes]) -> bytes:
    """Mux Opus packets into Ogg pages (about 1 s per page)."""
    out = bytearray()
    seq = 0

    def page(packets: list[bytes], granule: int, flags: int) -> None:
        nonlocal seq
        lacing, body = bytearray(), bytearray()
        for p in packets:
            lacing += bytes([255]) * (len(p) // 255) + bytes([len(p) % 255])
            body += p
        if len(lacing) > 255:
            raise OpusMuxError("page overflow")
        pg = (
            bytearray(b"OggS")
            + bytes([0, flags])
            + granule.to_bytes(8, "little", signed=True)
            + serial.to_bytes(4, "little")
            + seq.to_bytes(4, "little")
            + bytes(4)
            + bytes([len(lacing)])
            + lacing
            + body
        )
        pg[22:26] = ogg_crc(pg).to_bytes(4, "little")
        out.extend(pg)
        seq += 1

    page([head], 0, 0x02)
    page([tags], 0, 0x00)
    granule, group, lace = 0, [], 0
    for p in audio:
        need = len(p) // 255 + 1
        if group and (len(group) == 50 or lace + need > 255):
            page(group, granule, 0x00)
            group, lace = [], 0
        group.append(p)
        lace += need
        granule += opus_packet_samples(p)
    page(group, granule, 0x04)
    return bytes(out)


def circular_extension(pcm: bytes, frame_bytes: int) -> bytes:
    """``[tail | loop | head]`` of an interleaved PCM loop (``frame_bytes`` per sample frame):
    the samples the encoder must see around the loop (see ``remux_loop``)."""
    n = len(pcm) // frame_bytes
    preroll = PREROLL_FRAMES * OPUS_FRAME - OPUS_ENCODER_DELAY
    postroll = POSTROLL_FRAMES * OPUS_FRAME
    if n < preroll or n < postroll:
        raise OpusMuxError("loop too short")
    return pcm[(n - preroll) * frame_bytes :] + pcm + pcm[: postroll * frame_bytes]


def remux_loop(encoded: bytes, n: int) -> bytes:
    """From the Ogg Opus encoding of ``circular_extension(loop)``, the gapless loop file of
    exactly ``n`` samples (``n`` a whole number of 20 ms frames)."""
    if n % OPUS_FRAME:
        raise OpusMuxError("loop length is not a whole number of Opus frames")
    serial, packets, _ = ogg_packets(encoded)
    if len(packets) < 3:
        raise OpusMuxError("no audio packet")
    head, tags, audio = packets[0], packets[1], packets[2:]
    if head[:8] != b"OpusHead" or tags[:8] != b"OpusTags":
        raise OpusMuxError("unexpected Ogg Opus header")
    if int.from_bytes(head[10:12], "little") != OPUS_ENCODER_DELAY:
        raise OpusMuxError("unexpected libopus encoder delay")
    lead = PREROLL_FRAMES * OPUS_FRAME
    if sum(opus_packet_samples(p) for p in audio[:PREROLL_FRAMES]) != lead:
        raise OpusMuxError("unexpected Opus frame size")
    loop: list[bytes] = []
    total = 0
    for p in audio[PREROLL_FRAMES:]:
        if total >= n:
            break
        loop.append(p)
        total += opus_packet_samples(p)
    if total != n:
        raise OpusMuxError("loop length does not match the packets")
    warm: list[bytes] = []
    pre_skip = 0
    for p in reversed(loop):
        if pre_skip >= WARMUP_FRAMES * OPUS_FRAME:
            break
        warm.insert(0, p)
        pre_skip += opus_packet_samples(p)
    head = head[:10] + pre_skip.to_bytes(2, "little") + head[12:]
    return ogg_write(serial, head, tags, warm + loop)


def needs_end_trim(data: bytes) -> bool:
    """True if the packets decode to more samples than the final granule says."""
    _, packets, granule = ogg_packets(data)
    head = packets[0]
    pre_skip = int.from_bytes(head[10:12], "little")
    return sum(opus_packet_samples(p) for p in packets[2:]) != granule or granule < pre_skip
