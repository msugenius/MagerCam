#!/usr/bin/env python3
"""Verify a real MagerCam sender without OBS or third-party Python packages.

Run against the app's synthetic source or a camera the user has started:
    MG_KEY=123456 python3 Tests/check_stream.py 127.0.0.1
    MG_KEY=123456 python3 Tests/check_stream.py 192.168.1.10 --output-h264 sample.h264

The access code is never printed. H.264 export contains video, not MC headers.
"""

import argparse
import base64
import http.client
import io
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.parse


class CheckFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def request_json(host, port, path, key=None, expected=200):
    connection = http.client.HTTPConnection(host, port, timeout=5)
    try:
        headers = {"X-MagerCam-Key": key} if key is not None else {}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        body = response.read(65537)
        require(response.status == expected,
                "HTTP response was %d, expected %d" % (response.status, expected))
        require(len(body) <= 65536, "JSON response exceeds 64 KiB")
        if expected != 200:
            return None
        require("application/json" in response.getheader("Content-Type", ""),
                "Status response must advertise application/json")
        result = json.loads(body)
        require(isinstance(result, dict), "Status must be a JSON object")
        return result
    finally:
        connection.close()


def check_status(status):
    require(status.get("ver") == 2, "Expected protocol version 2")
    require(isinstance(status.get("name"), str) and status["name"], "Missing sender name")
    for field in ("w", "h", "fps"):
        require(isinstance(status.get(field), (int, float)) and status[field] > 0,
                "Missing or invalid status field: " + field)
    require(status.get("codec") == "h264", "This verifier expects the H.264 prototype")
    require(status.get("auth") is True, "Prototype should require an access code")
    require(status.get("audio") is False, "Video-only prototype must report audio=false")


def check_discovery(host, port, discovery_port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as discovery:
        discovery.settimeout(4)
        discovery.sendto(b"MAGERCAM_DISCOVER", (host, discovery_port))
        body, _ = discovery.recvfrom(4096)
    info = json.loads(body)
    require(info.get("magercam") == 1 and info.get("ver") == 2,
            "Discovery response has invalid protocol identifiers")
    require(info.get("port") == port, "Discovery advertises a different TCP port")
    require(info.get("auth") is True, "Discovery must advertise auth=true")
    require(bool(info.get("name")), "Discovery omitted the sender name")


def read_exact(reader, length):
    chunks = []
    remaining = length
    while remaining:
        chunk = reader.read(remaining)
        require(bool(chunk), "Connection ended in the middle of a packet")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_packet(reader):
    magic, packet_type, flags, length, pts = struct.unpack(
        ">2sBBIq", read_exact(reader, 16))
    require(magic == b"MC", "Invalid MC packet magic or stream framing")
    require(packet_type in range(1, 7), "Unknown MC packet type")
    require(length <= 32 * 1024 * 1024, "Packet exceeds Windows receiver's 32 MiB limit")
    return packet_type, flags, pts, read_exact(reader, length)


def nal_units(data):
    starts = list(re.finditer(b"\x00\x00(?:\x00)?\x01", data))
    require(starts and starts[0].start() == 0, "H.264 payload is not Annex-B")
    units = []
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(data)
        nal = data[start.end():end]
        require(bool(nal), "Empty H.264 NAL unit")
        require((nal[0] & 0x80) == 0, "Forbidden H.264 NAL header bit is set")
        units.append(nal)
    return units


class Bits:
    def __init__(self, data):
        self.data, self.offset = data, 0

    def read(self, count):
        require(self.offset + count <= len(self.data) * 8, "Truncated H.264 SPS")
        result = 0
        for _ in range(count):
            result = (result << 1) | ((self.data[self.offset // 8] >>
                                      (7 - self.offset % 8)) & 1)
            self.offset += 1
        return result

    def ue(self):
        zeros = 0
        while self.read(1) == 0:
            zeros += 1
            require(zeros <= 31, "Invalid Exp-Golomb value in SPS")
        return (1 << zeros) - 1 + self.read(zeros)

    def se(self):
        value = self.ue()
        return (value + 1) // 2 if value & 1 else -(value // 2)


def sps_dimensions(nal):
    # Remove emulation-prevention bytes before reading the RBSP bitstream.
    bits = Bits(re.sub(b"\x00\x00\x03", b"\x00\x00", nal[1:]))
    profile = bits.read(8)
    bits.read(16)  # constraint flags and level_idc
    bits.ue()  # seq_parameter_set_id
    chroma, separate = 1, 0
    if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        chroma = bits.ue()
        require(chroma <= 3, "Invalid chroma format in SPS")
        if chroma == 3:
            separate = bits.read(1)
        bits.ue(), bits.ue()  # bit depths
        bits.read(1)
        if bits.read(1):
            for index in range(12 if chroma == 3 else 8):
                if bits.read(1):
                    last, next_scale = 8, 8
                    for _ in range(16 if index < 6 else 64):
                        if next_scale:
                            next_scale = (last + bits.se() + 256) % 256
                        last = next_scale or last
    bits.ue()  # log2_max_frame_num_minus4
    order = bits.ue()
    if order == 0:
        bits.ue()
    elif order == 1:
        bits.read(1)
        bits.se(), bits.se()
        for _ in range(bits.ue()):
            bits.se()
    bits.ue()  # max_num_ref_frames
    bits.read(1)
    width, height = (bits.ue() + 1) * 16, (bits.ue() + 1) * 16
    frame_only = bits.read(1)
    height *= 2 - frame_only
    if not frame_only:
        bits.read(1)
    bits.read(1)
    if bits.read(1):
        left, right, top, bottom = bits.ue(), bits.ue(), bits.ue(), bits.ue()
        chroma_array = 0 if separate else chroma
        unit_x = (1, 2, 2, 1)[chroma_array]
        unit_y = (1, 2, 1, 1)[chroma_array] * (2 - frame_only)
        width -= (left + right) * unit_x
        height -= (top + bottom) * unit_y
    return width, height


class Stream:
    def __init__(self, host, port, key):
        self.connection = http.client.HTTPConnection(host, port, timeout=5)
        # Deliberately request Windows defaults, including HEVC capability. The
        # sender may select H.264/720p and must accurately describe that result.
        path = "/stream?w=1920&h=1080&fps=30&bitrate=8000&audio=0&camera=back&codec=hevc"
        self.connection.request("GET", path, headers={"X-MagerCam-Key": key})
        self.reader = self.connection.getresponse()
        require(self.reader.status == 200, "Stream request did not return HTTP 200")
        require(self.reader.getheader("Content-Type", "").split(";")[0] ==
                "application/x-magercam", "Incorrect stream Content-Type")
        require(self.reader.getheader("Transfer-Encoding") is None,
                "Windows receiver does not support HTTP chunked transfer framing")

    def close(self):
        self.reader.close()
        self.connection.close()


def check_video(stream, wanted_frames, status, output=None, require_high_profile=False):
    config, last_pts = None, None
    frames, idrs, statuses = 0, 0, 0
    deadline = time.monotonic() + max(10, wanted_frames / status["fps"] * 4)
    while frames < wanted_frames:
        require(time.monotonic() < deadline, "Timed out waiting for video frames")
        packet_type, flags, pts, payload = read_packet(stream.reader)
        if packet_type == 1:
            require((flags & 2) == 0, "Sender selected HEVC instead of H.264")
            require(payload != config, "Repeated VIDEO_CONFIG unnecessarily resets Windows decoder")
            nals = nal_units(payload)
            types = {nal[0] & 31 for nal in nals}
            require({7, 8}.issubset(types), "VIDEO_CONFIG must contain SPS and PPS")
            sps = next(nal for nal in nals if nal[0] & 31 == 7)
            if require_high_profile:
                require(len(sps) > 1 and sps[1] == 100,
                        "Expected H.264 High profile in the actual SPS")
                require(len(sps) > 3 and sps[3] <= 51,
                        "H.264 level exceeds the Windows decoder's documented level 5.1 limit")
            dimensions = sps_dimensions(sps)
            require(dimensions == (status["w"], status["h"]),
                    "SPS dimensions %s disagree with status %s" %
                    (dimensions, (status["w"], status["h"])))
            config = payload
            if output:
                output.write(payload)
        elif packet_type == 2:
            require(config is not None, "Video frame arrived before VIDEO_CONFIG")
            types = {nal[0] & 31 for nal in nal_units(payload)}
            require(bool(types.intersection({1, 5})), "Video access unit has no VCL NAL")
            keyframe = bool(flags & 1)
            require(keyframe == (5 in types), "MC keyframe flag disagrees with H.264 IDR NAL")
            require(frames > 0 or keyframe, "First frame must be an independently decodable IDR")
            require(pts >= 0 and (last_pts is None or pts > last_pts),
                    "Video timestamps must increase monotonically")
            if last_pts is not None:
                require(pts - last_pts <= 5_000_000, "Unexpected gap in video timestamps")
            last_pts = pts
            frames += 1
            idrs += keyframe
            if output:
                output.write(payload)
        elif packet_type == 5:
            check_status(json.loads(payload))
            statuses += 1
        elif packet_type == 6:
            require(not payload, "PING packet payload must be empty")
        else:
            raise CheckFailure("Video-only prototype unexpectedly sent audio packets")
    return frames, idrs, statuses


def self_check():
    # Fixed Baseline and High-profile SPS samples cover macroblock dimensions,
    # frame cropping, and emulation-prevention bytes independently of the sender.
    fixtures = [
        ("Z0IAH5WoFAFuQA==", (1280, 720)),
        ("Z2QAH6zZQFAFuhAAAAMAEAAAAwDxgxHg", (1280, 720)),
        ("Z0KAHtoCgPaEAAAAwAQAAAMAPI8UIZYA", (640, 480)),
        ("Z2QAKKzZQHgCJ+XARAAAAwAEAAADADw8WLZY", (1920, 1080)),
    ]
    for fixture, dimensions in fixtures:
        require(sps_dimensions(base64.b64decode(fixture)) == dimensions,
                "Verifier SPS parser failed its fixed fixture")
    units = nal_units(bytes.fromhex("000000016742001f00000168ce3c80"))
    require([unit[0] & 31 for unit in units] == [7, 8],
            "Verifier does not recognize mixed Annex-B start-code lengths")
    packet = bytes.fromhex("4d4302010000000501020304050607080000000165")
    require(read_packet(io.BytesIO(packet)) ==
            (2, 1, 0x0102030405060708, bytes.fromhex("0000000165")),
            "Verifier packet parser failed its wire-format fixture")
    for bad in (b"", b"\x67\x42", b"\x67\x64\x00\x28"):
        try:
            sps_dimensions(bad)
        except CheckFailure:
            continue
        raise CheckFailure("Verifier SPS parser accepted a truncated SPS")
    print("PASS: verifier SPS dimensions, Annex-B and MC wire-format fixtures")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", nargs="?", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4848)
    parser.add_argument("--discovery-port", type=int, default=4849)
    parser.add_argument("--key", default=os.environ.get("MG_KEY"))
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--skip-discovery", action="store_true")
    parser.add_argument("--output-h264")
    parser.add_argument("--expect-size", help="Require this source resolution, for example 1920x1080")
    parser.add_argument("--expect-bitrate", type=int, help="Require this target bitrate in kbit/s")
    parser.add_argument("--require-high-profile", action="store_true",
                        help="Require H.264 High profile in the encoded SPS")
    parser.add_argument("--self-test", action="store_true",
                        help="Check verifier fixtures without sockets, encoder or camera")
    args = parser.parse_args()
    if args.self_test:
        self_check()
        return
    require(args.key and re.fullmatch(r"[0-9]{6}", args.key),
            "Supply a six-digit access code through MG_KEY or --key")
    require(1 <= args.frames <= 10000, "--frames must be between 1 and 10000")
    request_json(args.host, args.port, "/api/status", expected=401)
    invalid_key = "000000" if args.key != "000000" else "999999"
    request_json(args.host, args.port, "/api/status", invalid_key, expected=401)
    status = request_json(args.host, args.port, "/api/status", args.key)
    check_status(status)
    if args.expect_size:
        require(re.fullmatch(r"[0-9]+x[0-9]+", args.expect_size), "--expect-size must be WIDTHxHEIGHT")
        expected_size = tuple(map(int, args.expect_size.split("x")))
        require((status["w"], status["h"]) == expected_size,
                "Source resolution does not match --expect-size")
    if args.expect_bitrate is not None:
        require(status.get("bitrate") == args.expect_bitrate,
                "Target bitrate does not match --expect-bitrate")
    query_status = request_json(args.host, args.port, "/api/status?" +
                                urllib.parse.urlencode({"key": args.key}))
    check_status(query_status)
    controls = request_json(args.host, args.port, "/api/set?torch=1&w=1920&fps=60", args.key)
    check_status(controls)
    require((controls["w"], controls["h"], controls["fps"]) ==
            (status["w"], status["h"], status["fps"]),
            "Fixed-format prototype changed format after unsupported controls")
    print("PASS: missing/incorrect code rejected; header/query authentication; truthful status")
    if not args.skip_discovery:
        check_discovery(args.host, args.port, args.discovery_port)
        print("PASS: UDP discovery advertises sender, protocol, port and authentication")
    output = open(args.output_h264, "wb") if args.output_h264 else None
    first, second = None, None
    try:
        first = Stream(args.host, args.port, args.key)
        frames, idrs, statuses = check_video(first, args.frames, status, output,
                                             require_high_profile=args.require_high_profile)
        print("PASS: %d H.264 frames, %d IDRs, %d status packets; %dx%d; increasing PTS" %
              (frames, idrs, statuses, status["w"], status["h"]))
        if args.require_high_profile:
            print("PASS: encoded H.264 High profile, level 5.1 or lower")
        if args.expect_bitrate is not None:
            print("PASS: configured target bitrate %d kbit/s" % args.expect_bitrate)
        # Keep the first connection open to test a client joining an active stream.
        second = Stream(args.host, args.port, args.key)
        check_video(second, min(args.frames, 5), status,
                    require_high_profile=args.require_high_profile)
        print("PASS: second client joins active stream with SPS/PPS and an initial IDR")
    finally:
        if second:
            second.close()
        if first:
            first.close()
        if output:
            output.close()
    print("All sender compatibility checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (CheckFailure, OSError, ValueError, http.client.HTTPException) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
