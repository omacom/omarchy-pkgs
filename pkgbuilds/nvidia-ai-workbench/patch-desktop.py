#!/usr/bin/env python3
"""Patch the pinned desktop's permission pass for package-managed helper files."""
import hashlib
import json
from pathlib import Path
import struct
import sys


def patch_main(data):
    guard = b'if(process.env.OMARCHY_NVWB_MANAGED==="1")return Promise.resolve({success:!0});'
    replacements = {
        b'function pi(e){return hi.apply(this,arguments)}':
        b'function pi(e){' + guard + b'return hi.apply(this,arguments)}',
        b'ci="0750",li=function(){var e=':
        b'ci="0750",li=function(){if(process.env.OMARCHY_NVWB_MANAGED==="1")return function(){return Promise.resolve({success:!0})};var e=',
    }
    for old, new in replacements.items():
        if data.count(old) != 1:
            raise ValueError('Vendor permission helper changed; review the desktop patch')
        data = data.replace(old, new)
    return data


def patch_archive(path):
    data = path.read_bytes()
    _, header_size, _, json_size = struct.unpack_from('<4I', data)
    header = json.loads(data[16:16 + json_size])
    payload = data[8 + header_size:]
    entry = header['files']['dist']['files']['main']['files']['main.js']
    offset, size = int(entry['offset']), entry['size']
    main = patch_main(payload[offset:offset + size])
    delta = len(main) - size
    def shift(files):
        for item in files.values():
            if 'files' in item:
                shift(item['files'])
            elif 'offset' in item and int(item['offset']) > offset:
                item['offset'] = str(int(item['offset']) + delta)
    shift(header['files'])
    entry['size'] = len(main)
    integrity = entry['integrity']
    assert integrity['algorithm'] == 'SHA256'
    block = integrity['blockSize']
    integrity['hash'] = hashlib.sha256(main).hexdigest()
    integrity['blocks'] = [hashlib.sha256(main[i:i + block]).hexdigest() for i in range(0, len(main), block)]
    encoded = json.dumps(header, separators=(',', ':'), ensure_ascii=False).encode()
    padded = encoded + b'\0' * (-len(encoded) % 4)
    prefix = struct.pack('<4I', 4, len(padded) + 8, len(padded) + 4, len(encoded))
    path.write_bytes(prefix + padded + payload[:offset] + main + payload[offset + size:])


if __name__ == '__main__':
    patch_archive(Path(sys.argv[1]))
