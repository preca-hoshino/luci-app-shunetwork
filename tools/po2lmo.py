"""Convert LuCI .po files to .lmo binary format.

Usage: python po2lmo.py input.po output.lmo

LMO format:
  - magic: 4 bytes "LMO\x00" (or 0x4C4D4F00)
  - For each string:
    - 4 bytes: hash of key
    - 4 bytes: offset to key string in string table
    - 4 bytes: offset to value string in string table
  - 4 bytes: 0x00000000 (end marker)
  - String table (null-terminated strings)
"""

import struct
import sys

def hash_lmo(key):
    h = 0
    for c in key:
        h = (h * 67 + ord(c)) & 0xFFFFFFFF
    return h

def parse_po(filename):
    entries = []
    current = None
    with open(filename, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line.startswith('msgid ') and not line.startswith('msgid_'):
                if current is not None and current['msgstr']:
                    entries.append(current)
                val = line[7:].strip('"')
                current = {'msgid': val, 'msgstr': ''}
            elif line.startswith('msgstr ') and current is not None:
                current['msgstr'] = line[8:].strip('"')
            elif current is not None and line.startswith('"') and not current.get('in_str'):
                current['msgid'] += line.strip('"')
    if current is not None and current['msgstr']:
        entries.append(current)
    return entries

def build_lmo(entries):
    # Filter out empty/meta entries and sort by hash
    data = []
    for e in entries:
        if e['msgid'] and e['msgstr']:
            data.append((hash_lmo(e['msgid']), e['msgid'].encode('utf-8'), e['msgstr'].encode('utf-8')))
    data.sort(key=lambda x: x[0])

    # Build string table
    string_table = b''
    offsets = []
    for h, key_bytes, val_bytes in data:
        offsets.append(len(string_table))
        string_table += key_bytes + b'\x00' + val_bytes + b'\x00'

    # Build index table: for each entry, 3 x 4 bytes (hash, key_offset, val_offset)
    index_table = b''
    for i, (h, key_bytes, val_bytes) in enumerate(data):
        key_off = offsets[i]
        # val offset is key offset + key len + 1
        val_off = key_off + len(key_bytes) + 1
        index_table += struct.pack('<III', h, key_off, val_off)

    # End marker
    index_table += struct.pack('<III', 0, 0, 0)

    # Magic
    magic = b'LMO\x00'

    return magic + index_table + string_table

def main():
    if len(sys.argv) != 3:
        print("Usage: python po2lmo.py input.po output.lmo", file=sys.stderr)
        sys.exit(1)

    entries = parse_po(sys.argv[1])
    lmo_data = build_lmo(entries)
    with open(sys.argv[2], 'wb') as f:
        f.write(lmo_data)
    print(f"Generated {sys.argv[2]} with {len(entries)} entries ({len(lmo_data)} bytes)")

if __name__ == '__main__':
    main()
