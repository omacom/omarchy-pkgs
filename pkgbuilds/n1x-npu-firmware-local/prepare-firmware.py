#!/usr/bin/python
# SPDX-License-Identifier: MIT
"""Extract hash-pinned SROOT images from a user-supplied Windows ARM64 KMD."""
import argparse
import hashlib
from pathlib import Path
import struct

KMD_SHA256='73b3187cdf84c0306df78595e49626d096e84dfc1e6356543db57b145007f987'
IMAGES=(('sroot-v0.bin',0x1405800,67508,'0f16911cced7bb95773da5aff9d9a44dfd1b1a11f3c560ee698a5c99310ff2c4'),
        ('sroot-v1.bin',0x13f5040,67508,'6b1e8192fc1e61944e9b2a84251b7d18f305025ffb2cfa1de8677f8f98b59ad4'))


def pe_slice(data,rva,size):
    offset=struct.unpack_from('<I',data,0x3c)[0]
    if data[offset:offset+4]!=b'PE\0\0' or struct.unpack_from('<H',data,offset+4)[0]!=0xaa64:
        raise ValueError('Expected ARM64 PE image')
    count=struct.unpack_from('<H',data,offset+6)[0]
    start=offset+24+struct.unpack_from('<H',data,offset+20)[0]
    for index in range(count):
        virtual_size,virtual_address,raw_size,raw_start=struct.unpack_from('<IIII',data,start+index*40+8)
        if virtual_address<=rva and rva+size<=virtual_address+min(virtual_size,raw_size):
            payload=data[raw_start+rva-virtual_address:raw_start+rva-virtual_address+size]
            if len(payload)==size:
                return payload
    raise ValueError('Firmware RVA is outside file-backed PE sections')


def prepare(kmd,output):
    data=kmd.read_bytes()
    if hashlib.sha256(data).hexdigest()!=KMD_SHA256:
        raise ValueError('KMD SHA256 mismatch; only the pinned 617.42 input is accepted')
    images=[(name,pe_slice(data,rva,size),sha) for name,rva,size,sha in IMAGES]
    for name,payload,sha in images:
        if hashlib.sha256(payload).hexdigest()!=sha:
            raise ValueError('Extracted firmware SHA256 mismatch: '+name)
    output.mkdir(parents=True,exist_ok=True)
    # Never replace an existing output, including a symlink.
    for name,_,_ in images:
        if (output/name).exists() or (output/name).is_symlink():
            raise ValueError('Output already exists: '+name)
    for name,payload,sha in images:
        with (output/name).open('xb') as stream:
            stream.write(payload)
        (output/name).chmod(0o600)
        print(sha+'  '+str(output/name))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kmd',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True,help='Explicit local destination; no service or module operation')
    args=parser.parse_args()
    prepare(args.kmd,args.output_dir)


if __name__=='__main__':
    main()
