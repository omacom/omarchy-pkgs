#!/usr/bin/env python3
"""Check Aura candidate metadata, with full qualification required by default."""
import argparse
import json
from pathlib import Path


def validate(record, commit, *, require_hardware=True):
    if record.get('source_commit') != commit:
        raise ValueError('Aura qualification source pin does not match the package')
    if record.get('stage1_auto_enrollment') is not False:
        raise ValueError('Aura package updates must not enroll Stage 1 automatically')
    if type(record.get('hardware_tested')) is not bool:
        raise ValueError('Aura hardware_tested must be a boolean')
    if not record['hardware_tested']:
        if not require_hardware:
            return
        raise ValueError('Aura publication blocked: the exact source pin is not hardware-qualified')
    evidence = record.get('evidence', {})
    for gate in ('native_build', 'matched_stage1_stage2_boot', 'repair', 'upgrade'):
        item = evidence.get(gate, {})
        if item.get('passed') is not True or not isinstance(item.get('report'), str) or not item['report'].strip():
            raise ValueError('Aura publication blocked: missing passing evidence for ' + gate)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true',
                        help='allow a candidate honestly marked as not hardware-tested')
    parser.add_argument('record', type=Path)
    parser.add_argument('commit')
    args = parser.parse_args()
    try:
        validate(json.loads(args.record.read_text()), args.commit,
                 require_hardware=not args.build_only)
    except (OSError, ValueError, KeyError, IndexError) as error:
        raise SystemExit(str(error)) from error
