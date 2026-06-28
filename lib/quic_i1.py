#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
quic_i1.py - offline generator of an AmneziaWG 2.0 I1 "Custom Protocol
Signature" packet that is a REAL, valid QUIC v1 Initial packet carrying a
TLS 1.3 ClientHello with a chosen SNI.

Why this exists
---------------
AmneziaWG 2.0's I1..I5 packets are sent before the real handshake to make the
session opener look like another UDP protocol. The community workflow generates
a QUIC-shaped I1 with a browser tool (sageptr.github.io/mini_quic_generator) and
pastes a fixed value. That has two problems for a hardened deployment:

  1. It needs a browser / online step -> not "one command, server does it all".
  2. Everyone copies the SAME example (often SNI=7-zip.org) -> a shared signature,
     which destroys the whole point of AmneziaWG 2.0 (per-deployment uniqueness).

This script builds a fresh, RANDOMIZED-per-run QUIC Initial entirely offline:
fully valid per RFC 9000 (transport) and RFC 9001 (Initial packet protection),
so a DPI that merely classifies UDP/443 as QUIC -- OR one that decrypts the
Initial and reads the SNI (GFW does this) -- sees a legitimate QUIC ClientHello.

Output is a single AmneziaWG CPS token:  I1 = <b 0x...>

Dependency: `cryptography` (apt: python3-cryptography, or pip: cryptography).

Self-test (`--selftest`): re-derives the Initial keys from the packet's DCID,
removes header protection, AEAD-decrypts, parses the CRYPTO frame and the
ClientHello, and asserts the SNI matches and the datagram is >= 1200 bytes
(the QUIC minimum for a client Initial). Exits non-zero on any failure, so the
installer can refuse to ship a malformed blob.
"""

import argparse
import os
import random
import struct
import sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.hazmat.primitives.hmac import HMAC
except Exception as exc:  # pragma: no cover - dependency missing
    sys.stderr.write("quic_i1.py: missing 'cryptography' module (%s)\n" % exc)
    sys.exit(3)

# RFC 9001 section 5.2 - QUIC v1 Initial salt.
INITIAL_SALT_V1 = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
QUIC_VERSION_1 = 0x00000001


# ---------------------------------------------------------------------------
# HKDF (RFC 5869) + TLS 1.3 HKDF-Expand-Label (RFC 8446 7.1)
# ---------------------------------------------------------------------------
def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    h = HMAC(salt, SHA256())
    h.update(ikm)
    return h.finalize()


def hkdf_expand_label(secret: bytes, label: str, length: int) -> bytes:
    full_label = b"tls13 " + label.encode("ascii")
    info = struct.pack("!H", length) + bytes([len(full_label)]) + full_label + b"\x00"
    return HKDFExpand(algorithm=SHA256(), length=length, info=info).derive(secret)


def initial_keys(dcid: bytes):
    """Return (key, iv, hp) for the CLIENT direction of an Initial packet."""
    initial_secret = hkdf_extract(INITIAL_SALT_V1, dcid)
    client_secret = hkdf_expand_label(initial_secret, "client in", 32)
    key = hkdf_expand_label(client_secret, "quic key", 16)
    iv = hkdf_expand_label(client_secret, "quic iv", 12)
    hp = hkdf_expand_label(client_secret, "quic hp", 16)
    return key, iv, hp


# ---------------------------------------------------------------------------
# QUIC variable-length integer (RFC 9000 16)
# ---------------------------------------------------------------------------
def varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("varint must be non-negative")
    if value <= 0x3F:
        return bytes([value])
    if value <= 0x3FFF:
        return struct.pack("!H", value | 0x4000)
    if value <= 0x3FFFFFFF:
        return struct.pack("!I", value | 0x80000000)
    if value <= 0x3FFFFFFFFFFFFFFF:
        return struct.pack("!Q", value | 0xC000000000000000)
    raise ValueError("varint too large")


def read_varint(buf: bytes, off: int):
    prefix = buf[off] >> 6
    if prefix == 0:
        return buf[off] & 0x3F, off + 1
    if prefix == 1:
        return (struct.unpack("!H", buf[off:off + 2])[0] & 0x3FFF), off + 2
    if prefix == 2:
        return (struct.unpack("!I", buf[off:off + 4])[0] & 0x3FFFFFFF), off + 4
    return (struct.unpack("!Q", buf[off:off + 8])[0] & 0x3FFFFFFFFFFFFFFF), off + 8


# ---------------------------------------------------------------------------
# Minimal but realistic TLS 1.3 ClientHello with SNI / ALPN(h3) / key_share
# ---------------------------------------------------------------------------
def _ext(ext_type: int, body: bytes) -> bytes:
    return struct.pack("!HH", ext_type, len(body)) + body


def sni_ascii(sni: str) -> str:
    """TLS SNI must be the A-label (punycode) form for IDNs."""
    if any(ord(c) > 127 for c in sni):
        return sni.encode("idna").decode("ascii")
    return sni


# GREASE values (RFC 8701) - browsers sprinkle these in; using a random one per
# run also makes the TLS fingerprint vary per deployment instead of being a fixed
# tell shared by every install.
GREASE_VALUES = [
    0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A, 0x4A4A, 0x5A5A, 0x6A6A, 0x7A7A,
    0x8A8A, 0x9A9A, 0xAAAA, 0xBABA, 0xCACA, 0xDADA, 0xEAEA, 0xFAFA,
]


def grease() -> int:
    return GREASE_VALUES[os.urandom(1)[0] % len(GREASE_VALUES)]


def _tp_int(pid: int, value: int) -> bytes:
    v = varint(value)
    return varint(pid) + varint(len(v)) + v


def _tp_raw(pid: int, data: bytes) -> bytes:
    return varint(pid) + varint(len(data)) + data


def build_transport_params(scid: bytes) -> bytes:
    # Plausible client values (not all-zero, which would be an obvious tell).
    # 0x0f initial_source_connection_id is MANDATORY for a client (RFC 9000 18.2).
    return (
        _tp_int(0x01, 30000)        # max_idle_timeout (ms)
        + _tp_int(0x03, 1472)       # max_udp_payload_size
        + _tp_int(0x04, 786432)     # initial_max_data
        + _tp_int(0x05, 524288)     # initial_max_stream_data_bidi_local
        + _tp_int(0x06, 524288)     # initial_max_stream_data_bidi_remote
        + _tp_int(0x07, 524288)     # initial_max_stream_data_uni
        + _tp_int(0x08, 100)        # initial_max_streams_bidi
        + _tp_int(0x09, 103)        # initial_max_streams_uni
        + _tp_int(0x0E, 8)          # active_connection_id_limit
        + _tp_raw(0x0F, scid)       # initial_source_connection_id (mandatory)
    )


def build_client_hello(sni: str, scid: bytes) -> bytes:
    sni_bytes = sni_ascii(sni).encode("ascii")
    name_entry = b"\x00" + struct.pack("!H", len(sni_bytes)) + sni_bytes  # host_name(0)

    exts = []
    exts.append(_ext(grease(), b""))                                       # GREASE (empty)
    exts.append(_ext(0x0000, struct.pack("!H", len(name_entry)) + name_entry))  # server_name

    groups = struct.pack("!H", grease()) + struct.pack("!HHH", 0x001D, 0x0017, 0x0018)
    exts.append(_ext(0x000A, struct.pack("!H", len(groups)) + groups))    # supported_groups

    sigalgs = struct.pack("!HHHHHHHH", 0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601)
    exts.append(_ext(0x000D, struct.pack("!H", len(sigalgs)) + sigalgs))  # signature_algorithms

    alpn = b"\x02h3"
    exts.append(_ext(0x0010, struct.pack("!H", len(alpn)) + alpn))        # ALPN: h3

    # supported_versions: GREASE + TLS 1.3
    exts.append(_ext(0x002B, b"\x04" + struct.pack("!H", grease()) + b"\x03\x04"))
    exts.append(_ext(0x002D, b"\x01\x01"))                                # psk_key_exchange_modes

    # key_share: GREASE group (1-byte) + x25519 (random pub)
    ks = struct.pack("!HH", grease(), 1) + b"\x00" + struct.pack("!HH", 0x001D, 32) + os.urandom(32)
    exts.append(_ext(0x0033, struct.pack("!H", len(ks)) + ks))            # key_share

    exts.append(_ext(0x0039, build_transport_params(scid)))               # quic_transport_parameters

    random.shuffle(exts)  # Chrome randomizes extension order; also adds per-deploy entropy
    extensions = b"".join(exts)

    body = (
        struct.pack("!H", 0x0303)         # legacy_version TLS 1.2
        + os.urandom(32)                   # random
        + b"\x00"                          # legacy_session_id MUST be empty in QUIC (RFC 9001 8.4)
        + struct.pack("!H", 8)             # cipher_suites length (4 suites)
        + struct.pack("!HHHH", grease(), 0x1301, 0x1302, 0x1303)
        + b"\x01\x00"                      # compression: null
        + struct.pack("!H", len(extensions)) + extensions
    )
    # Handshake header: client_hello(1) + 3-byte length
    return b"\x01" + struct.pack("!I", len(body))[1:] + body


# ---------------------------------------------------------------------------
# Assemble a protected QUIC v1 Initial packet
# ---------------------------------------------------------------------------
def build_initial(sni: str, target_len: int = None) -> bytes:
    if target_len is None:
        target_len = 1200 + int.from_bytes(os.urandom(1), "big") % 53  # 1200..1252

    dcid = os.urandom(8)
    scid = os.urandom(8)
    key, iv, hp = initial_keys(dcid)

    ch = build_client_hello(sni, scid)
    crypto_frame = b"\x06" + varint(0) + varint(len(ch)) + ch  # CRYPTO frame, offset 0

    # Real clients encode the first Initial's packet number (0) in a single byte.
    pn_len = 1
    pn = 0
    pn_bytes = pn.to_bytes(pn_len, "big")

    # Header bytes up to (but excluding) the Length field, to size the padding.
    # first(1) + version(4) + dcidlen(1)+dcid + scidlen(1)+scid + tokenlen(1) + length(2) + pn(pn_len)
    fixed_header_len = 1 + 4 + 1 + len(dcid) + 1 + len(scid) + 1 + 2 + pn_len
    # ciphertext = plaintext + 16 (AEAD tag)
    # total = fixed_header_len + len(plaintext) + 16
    plaintext_target = target_len - fixed_header_len - 16
    pad = plaintext_target - len(crypto_frame)
    if pad < 0:
        pad = 0
    plaintext = crypto_frame + (b"\x00" * pad)  # PADDING frames are 0x00

    length_field = pn_len + len(plaintext) + 16  # what "Length" varint must cover
    length_vi = varint(length_field)
    if len(length_vi) != 2:
        # Re-pad so the Length varint stays 2 bytes (keeps fixed_header_len correct).
        # For our sizes (~1.2kB) this branch should never trigger.
        raise RuntimeError("unexpected Length varint size %d" % len(length_vi))

    first_byte = 0xC0 | (pn_len - 1)  # long header, fixed bit, Initial type, pn_len
    header = (
        bytes([first_byte])
        + struct.pack("!I", QUIC_VERSION_1)
        + bytes([len(dcid)]) + dcid
        + bytes([len(scid)]) + scid
        + b"\x00"               # token length 0 (client Initial, no token)
        + length_vi
        + pn_bytes
    )
    aad = header  # AAD is the header with unprotected first byte + packet number

    nonce = bytes(a ^ b for a, b in zip(iv, (b"\x00" * (12 - pn_len)) + pn_bytes))
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, aad)

    # Header protection (RFC 9001 5.4). pn_len == 4 -> sample = ciphertext[0:16].
    sample = ciphertext[4 - pn_len:4 - pn_len + 16]
    enc = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
    mask = enc.update(sample) + enc.finalize()

    prot_first = first_byte ^ (mask[0] & 0x0F)  # long header: mask low 4 bits
    prot_pn = bytes(a ^ b for a, b in zip(pn_bytes, mask[1:1 + pn_len]))

    packet = (
        bytes([prot_first])
        + header[1:-pn_len]   # version..length (unchanged)
        + prot_pn
        + ciphertext
    )
    return packet


# ---------------------------------------------------------------------------
# Self-test: act as the QUIC server / DPI and recover the SNI.
# ---------------------------------------------------------------------------
def parse_sni_from_clienthello(ch: bytes) -> str:
    # Skip handshake header: type(1) + len(3)
    off = 4
    off += 2          # legacy_version
    off += 32         # random
    sid_len = ch[off]; off += 1 + sid_len
    cs_len = struct.unpack("!H", ch[off:off + 2])[0]; off += 2 + cs_len
    comp_len = ch[off]; off += 1 + comp_len
    ext_total = struct.unpack("!H", ch[off:off + 2])[0]; off += 2
    end = off + ext_total
    while off < end:
        etype, elen = struct.unpack("!HH", ch[off:off + 4]); off += 4
        ebody = ch[off:off + elen]; off += elen
        if etype == 0x0000:  # server_name
            # list_len(2), name_type(1), name_len(2), name
            name_len = struct.unpack("!H", ebody[3:5])[0]
            return ebody[5:5 + name_len].decode("ascii")
    raise ValueError("no SNI extension found")


def decrypt_and_check(packet: bytes, expected_sni: str) -> None:
    assert len(packet) >= 1200, "datagram < 1200 bytes (%d)" % len(packet)
    off = 0
    first = packet[off]; off += 1
    assert first & 0x80, "not a long header"
    assert first & 0x40, "fixed bit not set"
    version = struct.unpack("!I", packet[off:off + 4])[0]; off += 4
    assert version == QUIC_VERSION_1, "version != QUICv1"
    dcid_len = packet[off]; off += 1
    dcid = packet[off:off + dcid_len]; off += dcid_len
    scid_len = packet[off]; off += 1
    off += scid_len
    token_len, off = read_varint(packet, off)
    off += token_len
    _length, off = read_varint(packet, off)
    pn_offset = off

    key, iv, hp = initial_keys(dcid)
    sample = packet[pn_offset + 4:pn_offset + 4 + 16]
    enc = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
    mask = enc.update(sample) + enc.finalize()

    first_unprot = first ^ (mask[0] & 0x0F)
    pn_len = (first_unprot & 0x03) + 1
    pn_bytes = bytes(a ^ b for a, b in zip(packet[pn_offset:pn_offset + pn_len], mask[1:1 + pn_len]))
    pn = int.from_bytes(pn_bytes, "big")

    header = bytes([first_unprot]) + packet[1:pn_offset] + pn_bytes
    ciphertext = packet[pn_offset + pn_len:]
    nonce = bytes(a ^ b for a, b in zip(iv, (b"\x00" * (12 - pn_len)) + pn.to_bytes(pn_len, "big")))
    plaintext = AESGCM(key).decrypt(nonce, ciphertext, header)

    # Walk frames; find CRYPTO (0x06), ignore PADDING (0x00) / PING (0x01).
    p = 0
    ch = None
    while p < len(plaintext):
        ft = plaintext[p]
        if ft == 0x00 or ft == 0x01:
            p += 1
            continue
        if ft == 0x06:  # CRYPTO
            p += 1
            _crypto_off, p = read_varint(plaintext, p)
            clen, p = read_varint(plaintext, p)
            ch = plaintext[p:p + clen]; p += clen
            break
        raise ValueError("unexpected frame type 0x%02x" % ft)
    if ch is None:
        raise ValueError("no CRYPTO frame")
    got = parse_sni_from_clienthello(ch)
    want = sni_ascii(expected_sni)
    assert got == want, "SNI mismatch: got %r want %r" % (got, want)


def main():
    ap = argparse.ArgumentParser(description="Generate an AmneziaWG 2.0 QUIC-mimicry I1 token.")
    ap.add_argument("--sni", help="server name to embed in the fake ClientHello")
    ap.add_argument("--raw-hex", action="store_true", help="print only the hex (no '<b 0x...>' wrapper)")
    ap.add_argument("--selftest", action="store_true", help="run round-trip self-test and exit")
    args = ap.parse_args()

    if args.selftest:
        ok = 0
        for sni in ["example.com", "www.gov.uk", "static.licdn.com", "почта.рф"]:
            pkt = build_initial(sni)
            decrypt_and_check(pkt, sni)
            ok += 1
        sys.stderr.write("quic_i1.py selftest: %d/%d OK\n" % (ok, ok))
        return 0

    if not args.sni:
        ap.error("--sni is required (or use --selftest)")

    pkt = build_initial(args.sni)
    decrypt_and_check(pkt, args.sni)  # never emit a blob we cannot ourselves parse
    h = pkt.hex()
    if args.raw_hex:
        sys.stdout.write(h + "\n")
    else:
        sys.stdout.write("<b 0x%s>\n" % h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
