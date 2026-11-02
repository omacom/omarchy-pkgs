"""Preserve ASAR contents and offsets when patching the permission helpers."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from helpers import load_script

m = load_script('patch-desktop.py')


class DesktopPatch(unittest.TestCase):
    def test_archive_offsets_and_integrity(self):
        main = b'function pi(e){return hi.apply(this,arguments)};ci="0750",li=function(){var e=1;return e}()'
        trailing = b'unchanged resource'
        entry = {'size': len(main), 'offset': '0', 'integrity': {'algorithm': 'SHA256', 'blockSize': 64, 'hash': '', 'blocks': []}}
        header = {'files': {'dist': {'files': {'main': {'files': {'main.js': entry}}}}, 'other': {'offset': str(len(main)), 'size': len(trailing)}}}
        raw = json.dumps(header).encode(); padded = raw + b'\0' * (-len(raw) % 4)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'app.asar'
            path.write_bytes(struct.pack('<4I', 4, len(padded)+8, len(padded)+4, len(raw)) + padded + main + trailing)
            m.patch_archive(path)
            data = path.read_bytes()
        _, size, _, length = struct.unpack_from('<4I', data)
        head = json.loads(data[16:16+length]); payload = data[8+size:]
        item = head['files']['dist']['files']['main']['files']['main.js']
        changed = payload[:item['size']]
        self.assertEqual(changed.count(b'OMARCHY_NVWB_MANAGED'), 2)
        self.assertEqual(item['integrity']['hash'], hashlib.sha256(changed).hexdigest())
        other = head['files']['other']
        self.assertEqual(payload[int(other['offset']):], trailing)
        self.assertEqual(item['integrity']['blocks'], [hashlib.sha256(changed[i:i+64]).hexdigest() for i in range(0,len(changed),64)])

    def test_changed_vendor_code_is_rejected(self):
        with self.assertRaises(ValueError):
            m.patch_main(b'new vendor release')
