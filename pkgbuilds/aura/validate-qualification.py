#!/usr/bin/env python3
"""Refuse installable Aura packages until the exact pin has boot/repair/upgrade evidence."""
import json
from pathlib import Path
import sys


def validate(record, commit):
    if record.get('source_commit') != commit or record.get('hardware_tested') is not True:
        raise ValueError('Aura publication blocked: the exact source pin is not hardware-qualified')
    evidence = record.get('evidence', {})
    for gate in ('native_build', 'matched_stage1_stage2_boot', 'repair', 'upgrade'):
        item = evidence.get(gate, {})
        if item.get('passed') is not True or not isinstance(item.get('report'), str) or not item['report'].strip():
            raise ValueError('Aura publication blocked: missing passing evidence for ' + gate)
    if record.get('stage1_auto_enrollment') is not False:
        raise ValueError('Aura package updates must not enroll Stage 1 automatically')


if __name__ == '__main__':
    try:
        validate(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2])
    except (OSError, ValueError, KeyError, IndexError) as error:
        raise SystemExit(str(error)) from error
