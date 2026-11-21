#!/usr/bin/env python3
# A workflow step that calls a function from helpers/ sources that helper in
# the same step. Each run: block is a fresh shell, so a function sourced in an
# earlier step is gone: the Publish step of 3673f54c called plan_slots without
# sourcing helpers/artifact-helpers.sh, and every publish failed.
import pathlib, re, sys, yaml

root = pathlib.Path(__file__).resolve().parent.parent
defined = {}
for helper in sorted((root / 'helpers').glob('*.sh')):
    # An executable helper is a script steps run, not a library they source.
    if helper.stat().st_mode & 0o111:
        continue
    for name in re.findall(r'^([a-z_][a-z0-9_]*)\(\) *\{', helper.read_text(), re.M):
        defined.setdefault(name, set()).add(f'helpers/{helper.name}')

def code(run):
    # Comment lines name functions without calling them.
    return '\n'.join(line for line in run.splitlines() if not line.lstrip().startswith('#'))

failures = []
for workflow in sorted((root / '.github/workflows').glob('*.yml')):
    doc = yaml.safe_load(workflow.read_text())
    for job_id, job in (doc.get('jobs') or {}).items():
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run')
            if not run:
                continue
            body = code(run)
            for name, files in defined.items():
                if not re.search(rf'(?<![\w.-]){name}(?![\w.-])', body):
                    continue
                if not any(re.search(rf'(source|\.)\s+(\S*/)?{re.escape(f)}\b', body) for f in files):
                    label = step.get('name') or f'step {i + 1}'
                    failures.append(f'{workflow.name}: {job_id}: "{label}" calls {name} without sourcing {" or ".join(sorted(files))}')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: every workflow step that calls a helper function sources it')
