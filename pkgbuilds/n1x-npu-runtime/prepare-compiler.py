#!/usr/bin/python
# SPDX-License-Identifier: MIT
"""Verify and stage explicit local TensorRT compiler inputs, without download."""
import argparse
import hashlib
from pathlib import Path

INPUTS={'libnvdla_compiler.so':'28668e74ced3c04ca34f30d41b7ea1d39cabe791418fbad31fcfb009d5558ad9',
        'nvdla_compiler.dll':'0ef7c9366205a7151490f07b0df94a5e6908c94da32e83fabaaef5d06254147d'}


def stage(linux,windows,destination):
    payloads={name:path.read_bytes() for name,path in zip(INPUTS,(linux,windows))}
    for name,payload in payloads.items():
        if hashlib.sha256(payload).hexdigest()!=INPUTS[name]:
            raise ValueError('Pinned TensorRT 11.4 input SHA256 mismatch: '+name)
    destination.mkdir(parents=True,exist_ok=True)
    for name in payloads:
        if (destination/name).exists() or (destination/name).is_symlink():
            raise ValueError('Refusing existing output: '+name)
    for name,payload in payloads.items():
        with (destination/name).open('xb') as stream:
            stream.write(payload)
        (destination/name).chmod(0o644)
        print(INPUTS[name]+'  '+str(destination/name))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--linux-so',type=Path,required=True)
    parser.add_argument('--windows-dll',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    stage(args.linux_so,args.windows_dll,args.output_dir)
