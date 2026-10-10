#!/usr/bin/env python3
"""Exercise publish.yml's shell steps with real curl against a local HTTP server."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EMPTY = '{"artifacts": []}'


def workflow_step(marker):
    lines = (ROOT / '.github/workflows/publish.yml').read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == marker)
    start = next(i for i in range(start, len(lines)) if lines[i].strip() == 'run: |') + 1
    end = start
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith('          ')):
        end += 1
    return '\n'.join(line[10:] for line in lines[start:end])


@contextlib.contextmanager
def responses(sequence):
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            index = min(len(requests), len(sequence) - 1)
            requests.append(self.path)
            status, body, *delay = sequence[index]
            self.send_response(status)
            self.send_header('Content-Length', str(1000 if delay else len(body.encode())))
            self.end_headers()
            self.wfile.write(body.encode())
            self.wfile.flush()
            if delay:
                time.sleep(delay[0])

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/artifacts', requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class DiscoveryTests(unittest.TestCase):
    def run_step(self, step, sequence, errexit=True, attempt_timeout="",
                 arch="aarch64", plan_packages=""):
        with tempfile.TemporaryDirectory() as directory, responses(sequence) as (url, requests):
            work = Path(directory)
            (work / 'helpers').symlink_to(ROOT / 'helpers', target_is_directory=True)
            (work / 'bin').mkdir()
            (work / 'tmp').mkdir()
            matrix = {'include': [{'package': 'fixture', 'arch': arch,
                                    'channels': 'edge', 'publish_arches': arch}]}
            (work / 'bin/build-matrix').write_text('#!/bin/bash\necho ' + "'" + json.dumps(matrix) + "'\n")
            (work / 'bin/build-matrix').chmod(0o755)
            (work / 'bin/build').write_text('#!/bin/bash\necho "$*" >> build-calls\necho "==> Plan complete. Packages that would build: $TEST_BUILD_PACKAGES"\n')
            (work / 'bin/build').chmod(0o755)
            (work / 'plan.txt').write_text(f'fixture {arch} edge {arch}\n')
            script = ('source helpers/artifact-discovery.sh; latest_artifact owner/repo fixture'
                      if step == 'helper' else workflow_step('- id: list' if step == 'plan' else '- name: Collect artifacts'))
            replacements = {'github.event.inputs.packages': 'fixture', 'github.repository': 'owner/repo',
                            'github.run_id': '42', 'github.sha': 'abc', 'github.server_url': 'https://github.com',
                            'github.event_name': 'workflow_dispatch', 'needs.changes.outputs.matrix': json.dumps(matrix)}
            for key, value in replacements.items():
                script = script.replace('${{ ' + key + ' }}', value)
            prefix = '''
curl() {
  local args=("$@") i
  if [[ -n $TEST_MAX_TIME ]]; then
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ ${args[i]} == --max-time ]]; then args[i+1]=$TEST_MAX_TIME; fi
    done
  fi
  args[${#args[@]}-1]="$TEST_URL"
  command curl "${args[@]}"
}
git() { echo treehash; }
'''
            result = subprocess.run(['bash', *(['-e'] if errexit else []), '-c', prefix + script], cwd=work,
                                    env={**os.environ, 'GH_TOKEN': 'fixture', 'TEST_URL': url,
                                         'TEST_MAX_TIME': attempt_timeout, 'TEST_BUILD_PACKAGES': plan_packages,
                                         'TMPDIR': str(work / 'tmp'),
                                         'GITHUB_OUTPUT': str(work / 'output'),
                                         'GITHUB_STEP_SUMMARY': str(work / 'summary')},
                                    text=True, capture_output=True, timeout=35)
            self.assertEqual(list((work / 'tmp').iterdir()), [], 'lookup temporary file leaked')
            record = json.loads((work / 'publish-record.json').read_text()) if (work / 'publish-record.json').exists() else None
            build_calls = (work / 'build-calls').read_text().splitlines() if (work / 'build-calls').exists() else []
            outputs = dict(line.split('=', 1) for line in (work / 'output').read_text().splitlines()) if (work / 'output').exists() else {}
            return result, list(requests), record, build_calls, outputs

    def test_partial_timeout_response_is_discarded(self):
        partial = '{"artifacts": [{"expired": false, "unexpected": "partial'
        result, requests, _, _, _ = self.run_step('helper', [(200, partial, 0.7), (200, EMPTY)],
                                               attempt_timeout='0.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'null')
        self.assertEqual(len(requests), 2)

    def test_transient_http_statuses_recover(self):
        for status in [408, 429, 500, 502, 504]:
            with self.subTest(status=status):
                result, requests, _, _, _ = self.run_step('helper', [(status, 'temporary'), (200, EMPTY)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'null')
                self.assertEqual(len(requests), 2)

    def test_newest_unexpired_artifact_is_selected(self):
        def artifact(run, created, expired=False):
            return {'expired': expired, 'created_at': created, 'expires_at': '2026-10-10T00:00:00Z',
                    'archive_download_url': f'https://api.github.com/artifacts/{run}/zip',
                    'workflow_run': {'id': run}}
        newest = artifact(2, '2026-10-03T00:00:00Z')
        body = json.dumps({'artifacts': [newest, artifact(3, '2026-10-04T00:00:00Z', True),
                                         artifact(1, '2026-10-02T00:00:00Z')]})
        result, requests, _, _, _ = self.run_step('helper', [(503, 'unavailable'), (200, body)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), newest)
        self.assertEqual(len(requests), 2)
        result, _, _, build_calls, _ = self.run_step('plan', [(200, body)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reuse the build artifact (run 2, expires', result.stdout)
        self.assertNotIn('no build artifact:', result.stdout)
        self.assertFalse(build_calls)
        result, _, _, _, _ = self.run_step('helper', [(200, json.dumps({'artifacts': [artifact(3, 'now', True)]}))])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'null')

    def test_transient_503_recovers(self):
        for step in ['plan', 'collect']:
            with self.subTest(step=step):
                result, requests, _, _, _ = self.run_step(step, [(503, 'unavailable'), (200, EMPTY)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 2)

    def test_persistent_503_fails_closed(self):
        for step in ['plan', 'collect']:
            with self.subTest(step=step):
                result, requests, record, build_calls, _ = self.run_step(step, [(503, 'unavailable')])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(requests), 4)
                self.assertFalse(build_calls)
                if step == 'collect':
                    self.assertEqual(record['sources'][0]['source'], 'artifact-discovery-failed')
                    self.assertEqual(record['slots'], [])

    def test_auth_and_not_found_fail_without_retry(self):
        for status in [401, 403, 404, 501]:
            for step in ['plan', 'collect']:
                with self.subTest(status=status, step=step):
                    result, requests, _, build_calls, _ = self.run_step(step, [(status, '{"message":"denied"}')])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(len(requests), 1)
                    self.assertFalse(build_calls)

    def test_collection_does_not_depend_on_errexit(self):
        for response in [(403, '{"message":"denied"}'), (200, '{}')]:
            with self.subTest(response=response):
                result, _, record, build_calls, _ = self.run_step('collect', [response], errexit=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(build_calls)
                self.assertEqual(record['sources'][0]['source'], 'artifact-discovery-failed')
                self.assertEqual(record['slots'], [])

    def test_empty_success_skips_already_published_packages(self):
        for arch in ['aarch64', 'x86_64']:
            for step in ['plan', 'collect']:
                with self.subTest(arch=arch, step=step):
                    result, requests, _, build_calls, outputs = self.run_step(step, [(200, EMPTY)], arch=arch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(build_calls, [f'--dry-run --mirror edge --arch {arch} --package fixture'])
                    self.assertIn("already published at master's version", result.stdout)
                    if step == 'plan':
                        self.assertEqual(outputs['rebuild_count'], '0')
                        self.assertEqual(json.loads(outputs['rebuild']), {'include': []})

    def test_empty_success_schedules_native_rebuilds(self):
        runners = {'aarch64': ['ubuntu-24.04-arm'],
                   'x86_64': ['self-hosted', 'omarchy-builder']}
        for arch, runner in runners.items():
            with self.subTest(arch=arch):
                result, requests, _, build_calls, outputs = self.run_step(
                    'plan', [(200, EMPTY)], arch=arch, plan_packages='fixture')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 1)
                self.assertEqual(build_calls, [f'--dry-run --mirror edge --arch {arch} --package fixture'])
                self.assertEqual(outputs['rebuild_count'], '1')
                rebuild = json.loads(outputs['rebuild'])['include']
                self.assertEqual(len(rebuild), 1)
                self.assertEqual(rebuild[0]['arch'], arch)
                self.assertEqual(json.loads(rebuild[0]['runner']), runner)

    def test_collection_fails_without_rebuild_artifact(self):
        for arch in ['aarch64', 'x86_64']:
            with self.subTest(arch=arch):
                result, requests, record, build_calls, _ = self.run_step(
                    'collect', [(200, EMPTY)], arch=arch, plan_packages='fixture')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(requests), 1)
                self.assertEqual(build_calls, [f'--dry-run --mirror edge --arch {arch} --package fixture'])
                self.assertEqual(record['sources'][0]['source'], 'build-failed')
                self.assertEqual(record['slots'], [])

    def test_invalid_success_is_not_empty(self):
        for body in ['', 'not json', '{}', '{"artifacts":null}', '{"artifacts":[{}]}', '{} {}', '{"artifacts": []} {"artifacts": []}']:
            for step in ['plan', 'collect']:
                with self.subTest(body=body, step=step):
                    result, _, _, build_calls, _ = self.run_step(step, [(200, body)])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(build_calls)


if __name__ == '__main__':
    unittest.main()
