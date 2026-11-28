#!/usr/bin/env python3
"""Self-test for ci/controller-box/create.sh and cloud-init.yaml."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CREATE_SCRIPT = ROOT / "ci/controller-box/create.sh"
TEST_SSH_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey"
SECOND_SSH_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecondKey"
VALID_FINGERPRINT = "3b:16:bf:e4:8b:00:8b:b8:59:8c:a9:d3:f0:19:45:fa"

CURL_STUB = f"""#!/usr/bin/env python3
import os
from pathlib import Path
import sys

method = "GET"
data = ""
url = ""
args = iter(sys.argv[1:])
for arg in args:
    if arg == "-X":
        method = next(args)
    elif arg == "-d":
        data = next(args)
    elif arg == "-H":
        next(args)
    elif not arg.startswith("-"):
        url = arg

with Path(os.environ["CURL_LOG"]).open("a") as log:
    log.write(f"{{method}} {{url}}\\n")

if url == "https://github.com/missing.keys":
    sys.exit(22)
elif url == "https://github.com/blank.keys":
    print("   \\n")
elif url == "https://github.com/seconduser.keys":
    print({SECOND_SSH_KEY!r}, end="")
elif url.startswith("https://github.com/") and url.endswith(".keys"):
    print({TEST_SSH_KEY!r}, end="")
elif url == "https://api.digitalocean.com/v2/droplets?tag_name=omarchy-controller":
    print('{{"droplets":[]}}')
elif url == "https://api.digitalocean.com/v2/droplets":
    if method != "POST":
        sys.exit(f"unexpected method {{method}}")
    Path(os.environ["POST_BODY"]).write_text(data)
    print('{{"droplet":{{"name":"omarchy-controller","id":42}}}}')
else:
    sys.exit(f"unexpected curl url: {{url}}")
"""


class ControllerBoxTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="controller-box-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text(CURL_STUB)
        curl.chmod(0o755)
        self.post_body = root / "post-body.json"
        self.curl_log = root / "curl.log"
        self.base_env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("DO_SSH_KEYS", "SSH_KEYS", "REPO", "REGION", "NAME")
        }
        self.base_env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            POST_BODY=str(self.post_body),
            CURL_LOG=str(self.curl_log),
            DIGITALOCEAN_TOKEN="do-test-token",
            GITHUB_TOKEN="gh-test-token",
            ADMIN_GITHUB_USERS="testuser",
        )

    def run_create(self, *args, script=CREATE_SCRIPT, **extra_env):
        self.post_body.unlink(missing_ok=True)
        self.curl_log.unlink(missing_ok=True)
        return subprocess.run(
            [str(script), *args],
            env=self.base_env | extra_env,
            capture_output=True,
            text=True,
        )

    def env_map(self, cfg):
        env_entries = [
            f
            for f in cfg.get("write_files", [])
            if f.get("path") == "/etc/omarchy-controller.env"
        ]
        self.assertEqual(len(env_entries), 1)
        result = {}
        for line in base64.b64decode(env_entries[0]["content"]).decode().splitlines():
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key] = value
        return result

    def test_rejects_invalid_keys(self):
        invalid_cases = [
            ("unset", {}),
            ("empty DO_SSH_KEYS overrides fallback", {"DO_SSH_KEYS": "", "SSH_KEYS": "[123]"}),
            ("empty SSH_KEYS alongside DO_SSH_KEYS", {"DO_SSH_KEYS": "[123]", "SSH_KEYS": ""}),
            ("empty array", {"DO_SSH_KEYS": "[]"}),
            ("non-json", {"DO_SSH_KEYS": "not-json"}),
            ("non-positive id", {"DO_SSH_KEYS": "[0]"}),
            ("short fingerprint", {"DO_SSH_KEYS": '["aa:bb:cc"]'}),
            ("trailing data", {"DO_SSH_KEYS": "[123] [456]"}),
        ]
        for label, extra_env in invalid_cases:
            with self.subTest(case=label):
                proc = self.run_create(**extra_env)
                self.assertNotEqual(proc.returncode, 0, f"expected failure: {label}")
                self.assertFalse(self.curl_log.exists(), f"unexpected network call: {label}")
                self.assertFalse(self.post_body.exists(), f"unexpected request body: {label}")

    def test_rejects_invalid_branch(self):
        for bad in ("-bad", "HEAD", "@{-1}", "bad branch"):
            with self.subTest(branch=bad):
                proc = self.run_create(bad, DO_SSH_KEYS="[123]")
                self.assertNotEqual(proc.returncode, 0, f"expected failure for branch {bad!r}")
                self.assertFalse(self.curl_log.exists(), f"unexpected network call for branch {bad!r}")
                self.assertFalse(self.post_body.exists(), f"unexpected request body for branch {bad!r}")

    def test_renders_defaults(self):
        branch = "feature/foo+__CI__"
        proc = self.run_create(
            branch,
            DO_SSH_KEYS=json.dumps([123, VALID_FINGERPRINT]),
            ADMIN_GITHUB_USERS="testuser seconduser",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(self.post_body.is_file())

        body = json.loads(self.post_body.read_text())
        self.assertEqual(body["ssh_keys"], [123, VALID_FINGERPRINT])

        user_data = body["user_data"]
        self.assertTrue(user_data.startswith("#cloud-config\n"))
        cfg = yaml.safe_load(user_data)
        self.assertIs(cfg.get("disable_root"), False)
        self.assertIs(cfg.get("ssh_pwauth"), False)
        self.assertNotIn("chpasswd", cfg)
        self.assertEqual(
            cfg.get("ssh_authorized_keys"),
            [TEST_SSH_KEY, SECOND_SSH_KEY],
        )

        env = self.env_map(cfg)
        self.assertEqual(env.get("DO_SSH_KEYS"), f'[123,"{VALID_FINGERPRINT}"]')
        self.assertEqual(
            json.loads(env["SSH_KEYS_JSON"]),
            [TEST_SSH_KEY, SECOND_SSH_KEY],
        )

        runcmd = cfg.get("runcmd", [])
        self.assertTrue(runcmd and runcmd[0] == "set -e")
        self.assertLess(
            runcmd.index('chage -d "$(date +%F)" -M -1 root'),
            runcmd.index("passwd -l root"),
        )
        self.assertIn("chown root:controller /etc/omarchy-controller.env", runcmd)
        self.assertIn("chmod 0640 /etc/omarchy-controller.env", runcmd)
        self.assertIn("mkdir -p /run/omarchy-controller", runcmd)
        self.assertIn("chown controller:controller /run/omarchy-controller", runcmd)
        self.assertIn(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                branch,
                "https://github.com/omacom/omarchy-pkgs.git",
                "/opt/omarchy-pkgs",
            ],
            runcmd,
        )

    def test_separate_controller_and_builder_keys(self):
        proc = self.run_create(DO_SSH_KEYS="[123]", SSH_KEYS="[456]")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        body = json.loads(self.post_body.read_text())
        self.assertEqual(body["ssh_keys"], [456])
        cfg = yaml.safe_load(body["user_data"])
        self.assertEqual(self.env_map(cfg).get("DO_SSH_KEYS"), "[123]")

    def test_legacy_fallback(self):
        proc = self.run_create(SSH_KEYS="[456]")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        body = json.loads(self.post_body.read_text())
        self.assertEqual(body["ssh_keys"], [456])
        cfg = yaml.safe_load(body["user_data"])
        example_default = next(
            line.split("=", 1)[1]
            for line in (ROOT / "ci/controller-box/controller.env.example").read_text().splitlines()
            if line.startswith("DO_SSH_KEYS=")
        )
        self.assertEqual(self.env_map(cfg).get("DO_SSH_KEYS"), example_default)

    def test_stops_on_fetch_error(self):
        proc = self.run_create(
            DO_SSH_KEYS="[123]",
            ADMIN_GITHUB_USERS="testuser missing seconduser",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(
            self.curl_log.read_text().splitlines(),
            [
                "GET https://github.com/testuser.keys",
                "GET https://github.com/missing.keys",
            ],
        )
        self.assertFalse(self.post_body.exists())

    def test_rejects_blank_key_list(self):
        for label, users, expected_calls in (
            (
                "mixed valid and blank user",
                "testuser blank seconduser",
                [
                    "GET https://github.com/testuser.keys",
                    "GET https://github.com/blank.keys",
                ],
            ),
            ("whitespace-only user list", "   ", []),
        ):
            with self.subTest(case=label):
                proc = self.run_create(DO_SSH_KEYS="[123]", ADMIN_GITHUB_USERS=users)
                self.assertNotEqual(proc.returncode, 0, f"expected failure: {label}")
                self.assertFalse(self.post_body.exists(), f"unexpected request body: {label}")
                actual_calls = self.curl_log.read_text().splitlines() if self.curl_log.exists() else []
                self.assertEqual(actual_calls, expected_calls)

    def test_rejects_unsubstituted_placeholder(self):
        for label, mutate in (
            ("extra placeholder", lambda text: text + "  - echo __UNSUBSTITUTED_TOKEN__\n"),
            ("unmatched template line", lambda text: text.replace("--depth 1 ", "--depth 2 ")),
        ):
            with self.subTest(case=label):
                box_dir = Path(self.temp.name) / label.replace(" ", "-")
                box_dir.mkdir()
                for name in ("create.sh", "controller.env.example", "cloud-init.yaml"):
                    shutil.copy2(ROOT / "ci/controller-box" / name, box_dir / name)
                cloud_init = box_dir / "cloud-init.yaml"
                cloud_init.write_text(mutate(cloud_init.read_text()))

                proc = self.run_create(script=box_dir / "create.sh", DO_SSH_KEYS="[123]")
                self.assertNotEqual(proc.returncode, 0, f"expected failure: {label}")
                self.assertIn("placeholder", proc.stderr.lower())
                self.assertFalse(self.curl_log.exists(), f"unexpected network call: {label}")
                self.assertFalse(self.post_body.exists(), f"unexpected request body: {label}")


if __name__ == "__main__":
    unittest.main()
