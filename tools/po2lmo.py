#!/usr/bin/env python3
"""Convert LuCI .po files to .lmo binary format.

Format verified against openwrt/luci modules/luci-base/src/po2lmo.c
and lib/lmo.c:

  [ string table ]  all msgstr values, each padded to 4 bytes with \0
  [ index ]         entries sorted by key_id ascending, 16 bytes each:
                    key_id / val_id / offset / length as BIG-ENDIAN u32
  [ trailer ]       4 bytes big-endian u32: start offset of the index

key_id = sfh_hash(canonicalised msgid)  (SuperFastHash, init = len)
val_id = plural_num + 1                 (1 for plain entries)

Usage: python po2lmo.py input.po output.lmo
"""

import struct
import sys

_MASK = 0xFFFFFFFF


def _get16(data, pos):
    return data[pos] | (data[pos + 1] << 8)


def _schar(b):
    return b - 256 if b >= 128 else b


def sfh_hash(data, init):
    """Paul Hsieh's SuperFastHash, matching luci's lib/sfh (mod 2^32)."""
    length = len(data)
    if length == 0:
        return 0
    h = init & _MASK
    rem = length & 3
    pos = 0
    for _ in range(length >> 2):
        h = (h + _get16(data, pos)) & _MASK
        tmp = ((_get16(data, pos + 2) << 11) ^ h) & _MASK
        h = ((h << 16) ^ tmp) & _MASK
        pos += 4
        h = (h + (h >> 11)) & _MASK
    if rem == 3:
        h = (h + _get16(data, pos)) & _MASK
        h = (h ^ ((h << 16) & _MASK)) & _MASK
        h = (h ^ ((_schar(data[pos + 2]) << 18) & _MASK)) & _MASK
        h = (h + (h >> 11)) & _MASK
    elif rem == 2:
        h = (h + _get16(data, pos)) & _MASK
        h = (h ^ ((h << 11) & _MASK)) & _MASK
        h = (h + (h >> 17)) & _MASK
    elif rem == 1:
        h = (h + _schar(data[pos])) & _MASK
        h = (h ^ ((h << 10) & _MASK)) & _MASK
        h = (h + (h >> 1)) & _MASK
    h = (h ^ ((h << 3) & _MASK)) & _MASK
    h = (h + (h >> 5)) & _MASK
    h = (h ^ ((h << 4) & _MASK)) & _MASK
    h = (h + (h >> 17)) & _MASK
    h = (h ^ ((h << 25) & _MASK)) & _MASK
    h = (h + (h >> 6)) & _MASK
    return h


def canon(text):
    """lmo_canon_hash whitespace handling: collapse runs of whitespace
    into a single space and strip leading/trailing whitespace."""
    out = []
    prev_space = True
    for ch in text:
        if ch.isspace():
            if not prev_space:
                out.append(" ")
            prev_space = True
        else:
            out.append(ch)
            prev_space = False
    if out and out[-1] == " ":
        out.pop()
    return "".join(out).encode("utf-8")


def _unquote(line):
    start = line.find('"')
    if start < 0:
        return None
    out = []
    esc = False
    for ch in line[start + 1:]:
        if esc:
            out.append({"n": "\n", "t": "\t", "r": "\r"}.get(ch, ch))
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            break
        else:
            out.append(ch)
    return "".join(out)


def parse_po(path):
    pairs = []
    msgid = msgstr = None
    cur = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("msgid "):
                if msgid and msgstr:
                    pairs.append((msgid, msgstr))
                msgid, msgstr, cur = _unquote(line) or "", None, "id"
            elif line.startswith("msgstr "):
                msgstr, cur = _unquote(line) or "", "str"
            elif line.startswith('"') and cur:
                part = _unquote(line)
                if part:
                    if cur == "id":
                        msgid = (msgid or "") + part
                    else:
                        msgstr = (msgstr or "") + part
            elif line.startswith("msgctxt") or line.startswith("msgid_plural"):
                cur = None
    if msgid and msgstr:
        pairs.append((msgid, msgstr))
    return pairs


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: po2lmo.py input.po output.lmo")

    strings = bytearray()
    entries = []
    offset = 0

    for msgid, msgstr in parse_po(sys.argv[1]):
        key = canon(msgid)
        val = msgstr.encode("utf-8")
        if not key or not val:
            continue
        key_id = sfh_hash(key, len(key))
        if key_id == sfh_hash(val, len(val)):
            continue  # untranslated entry, same as upstream po2lmo
        strings += val
        pad = (4 - (len(val) % 4)) % 4
        strings += b"\0" * pad
        entries.append((key_id, 1, offset, len(val)))
        offset += len(val) + pad

    entries.sort(key=lambda e: e[0])

    with open(sys.argv[2], "wb") as out:
        out.write(bytes(strings))
        for key_id, val_id, off, ln in entries:
            out.write(struct.pack(">IIII", key_id, val_id, off, ln))
        out.write(struct.pack(">I", offset))

    print(f"Generated {sys.argv[2]} with {len(entries)} entries ({offset + 4 + 16 * len(entries)} bytes)")


if __name__ == "__main__":
    main()
