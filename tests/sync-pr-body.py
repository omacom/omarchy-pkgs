#!/usr/bin/env python3
"""Offline tests for helpers/sync-pr-body.py, the sync PRs' description.

Each test builds a small repository: a base commit with one or more recipes,
then the working-tree change a sync would make. The description is built from
that change alone, plus an injected GitHub release lookup where the source is a
GitHub tag. Nothing here touches the network.
"""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "helpers/sync-pr-body.py"
spec = importlib.util.spec_from_file_location("sync_pr_body", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

SHA = {name: (name * 64)[:64] for name in "abcdef0123456789"}


def recipe(pkgver, pkgrel="1", arch="('x86_64' 'aarch64')", body=""):
    return f"pkgname=tool\npkgver={pkgver}\npkgrel={pkgrel}\narch={arch}\n{body}\npackage() {{ :; }}\n"


class Repo:
    def __init__(self, test):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        self.git("init", "-q")

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t.test", *args],
                              cwd=self.root, check=True, capture_output=True, text=True).stdout

    def write(self, package, pkgbuild=None, metadata=None, files=None):
        path = self.root / "pkgbuilds" / package
        (path / ".omarchy").mkdir(parents=True, exist_ok=True)
        if pkgbuild is not None:
            (path / "PKGBUILD").write_text(pkgbuild.replace("pkgname=tool", f"pkgname={package}"))
        if metadata is not None:
            (path / ".omarchy/package.json").write_text(json.dumps(metadata, indent=2) + "\n")
        for name, text in (files or {}).items():
            (path / name).write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")


class FakeGitHub:
    """Answers release lookups from a dict; records every URL asked for."""

    def __init__(self, releases=None, fail=False):
        self.releases = releases or {}
        self.fail = fail
        self.calls = []

    def __call__(self, url):
        self.calls.append(url)
        if self.fail:
            raise OSError("network down")
        if url not in self.releases:
            raise FileNotFoundError(url)
        return self.releases[url]


def release(repo, tag, body="", published="2026-11-19T20:49:07Z", digests=None):
    return {
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}": {
            "tag_name": tag,
            "html_url": f"https://github.com/{repo}/releases/tag/{tag}",
            "published_at": published,
            "body": body,
            "assets": [{"browser_download_url": url, "digest": f"sha256:{value}"} for url, value in (digests or {}).items()],
        }
    }


def hidden(body):
    """The record tools read: the last one, which release notes cannot follow."""
    start = body.rindex("<!-- omarchy-sync-pr ")
    return json.loads(body[start + len("<!-- omarchy-sync-pr "):body.rindex(" -->")])


class GitHubRefTest(unittest.TestCase):
    def test_reads_the_repository_and_ref_from_every_github_source_shape(self):
        cases = {
            "https://github.com/o/r/releases/download/v1.2/r-1.2.tar.gz": ("o/r", "tag", "v1.2"),
            "r.tar.gz::https://github.com/o/r/archive/refs/tags/desktop-v2026.11.0.tar.gz": ("o/r", "tag", "desktop-v2026.11.0"),
            "https://github.com/o/r/archive/v3.1.0.zip": ("o/r", "tag", "v3.1.0"),
            "https://github.com/o/r/archive/" + "a" * 40 + ".tar.gz": ("o/r", "commit", "a" * 40),
            "git+https://github.com/o/r.git#tag=release/1.0": ("o/r", "tag", "release/1.0"),
            "git+https://github.com/o/r#commit=" + "b" * 40: ("o/r", "commit", "b" * 40),
            "https://codeload.github.com/o/r/tar.gz/refs/tags/v2": ("o/r", "tag", "v2"),
            "CHANGELOG.md::https://raw.githubusercontent.com/o/r/v1.0.116/changelog.md": ("o/r", "tag", "v1.0.116"),
            "https://github.com/o/r/raw/" + "d" * 40 + "/fonts/x.ttf": ("o/r", "commit", "d" * 40),
            "https://github.com/o/r/raw/v2.0/fonts/x.ttf": ("o/r", "tag", "v2.0"),
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(m.github_ref(url), expected)

    def test_a_release_asset_is_a_tag_even_when_it_looks_like_a_commit(self):
        hexa = "c" * 40
        self.assertEqual(m.github_ref(f"https://github.com/o/r/releases/download/{hexa}/r.tar.gz"), ("o/r", "tag", hexa))

    def test_ignores_sources_that_are_not_github_refs(self):
        for url in ["https://github.com/o/r/archive/refs/heads/main.tar.gz",
                    "https://github.com/o/r/raw/refs/heads/main/x.ttf",
                    "https://codeload.github.com/o/r/tar.gz/refs/heads/main","https://example.test/tool.tar.gz", "local.patch",
                    "https://github.com/o/r/releases/latest/download/tool.tar.gz",
                    "https://gitlab.com/o/r/-/archive/v1/r-v1.tar.gz"]:
            with self.subTest(url=url):
                self.assertIsNone(m.github_ref(url))


class BodyTest(unittest.TestCase):
    def setUp(self):
        self.repo = Repo(self)

    def body(self, *packages, fetch=None, review=False):
        return m.build_body(self.repo.root, list(packages), base="HEAD", review=review, fetch_json=fetch)

    def github_tool(self, old, new, metadata=None, old_sums=("a", "b"), new_sums=("c", "d")):
        sources = ('source_x86_64=("https://github.com/owner/tool/releases/download/v${pkgver}/tool-${pkgver}-x64.tar.gz")\n'
                   'source_aarch64=("https://github.com/owner/tool/releases/download/v${pkgver}/tool-${pkgver}-arm64.tar.gz")\n')
        sums = "sha256sums_x86_64=('{}')\nsha256sums_aarch64=('{}')\n"
        meta = metadata or {"source": "local", "upstream": {"watch": {"github": "owner/tool", "pattern": r"v(?P<version>[0-9.]+)"}}}
        self.repo.write("tool", recipe(old, body=sources + sums.format(SHA[old_sums[0]], SHA[old_sums[1]])), meta)
        self.repo.commit()
        self.repo.write("tool", recipe(new, body=sources + sums.format(SHA[new_sums[0]], SHA[new_sums[1]])))

    def test_a_github_release_gets_its_link_date_compare_digest_check_and_notes(self):
        self.github_tool("1.2.0", "1.3.0")
        fetch = FakeGitHub(release("owner/tool", "v1.3.0", body="## Fixes\n- a fix", digests={
            "https://github.com/owner/tool/releases/download/v1.3.0/tool-1.3.0-x64.tar.gz": SHA["c"],
            "https://github.com/owner/tool/releases/download/v1.3.0/tool-1.3.0-arm64.tar.gz": SHA["d"],
        }))
        body = self.body("tool", fetch=fetch)
        self.assertIn("Updates **tool** from `1.2.0-1` to `1.3.0-1` (minor).", body)
        self.assertIn("| Source | GitHub releases of [owner/tool](https://github.com/owner/tool/releases) |", body)
        self.assertIn("| Release | [v1.3.0](https://github.com/owner/tool/releases/tag/v1.3.0), published 2026-11-19 |", body)
        self.assertIn("| Changes | [`v1.2.0...v1.3.0`](https://github.com/owner/tool/compare/v1.2.0...v1.3.0) |", body)
        self.assertIn("| Verification | sha256 of each changed checksum matches the digest GitHub lists for its asset |", body)
        self.assertIn("| x86_64 | [`tool-1.3.0-x64.tar.gz`](https://github.com/owner/tool/releases/download/v1.3.0/tool-1.3.0-x64.tar.gz) | sha256 `aaaaaaaa…` → `cccccccc…` |", body)
        self.assertIn("| aarch64 | [`tool-1.3.0-arm64.tar.gz`](https://github.com/owner/tool/releases/download/v1.3.0/tool-1.3.0-arm64.tar.gz) | sha256 `bbbbbbbb…` → `dddddddd…` |", body)
        self.assertIn("<summary>Release notes for v1.3.0</summary>", body)
        self.assertIn("\n    ## Fixes\n    - a fix\n", body)
        self.assertEqual(fetch.calls, ["https://api.github.com/repos/owner/tool/releases/tags/v1.3.0"])

    def test_a_digest_that_differs_or_is_missing_is_not_called_verified(self):
        self.github_tool("1.2.0", "1.3.0")
        fetch = FakeGitHub(release("owner/tool", "v1.3.0", digests={
            "https://github.com/owner/tool/releases/download/v1.3.0/tool-1.3.0-x64.tar.gz": SHA["e"],
        }))
        body = self.body("tool", fetch=fetch)
        self.assertIn("| Verification | checksums recorded by the sync |", body)
        self.assertNotIn("matches the digest", body)

    def test_without_the_network_the_offline_facts_still_render(self):
        self.github_tool("1.2.0", "1.3.0")
        fetch = FakeGitHub(fail=True)
        body = self.body("tool", fetch=fetch)
        self.assertIn("[`v1.2.0...v1.3.0`](https://github.com/owner/tool/compare/v1.2.0...v1.3.0)", body)
        self.assertIn("| Tag | [`v1.3.0`](https://github.com/owner/tool/tree/v1.3.0) |", body)
        self.assertNotIn("| Release |", body)
        self.assertNotIn("Release notes", body)
        self.assertEqual(self.body("tool", fetch=None), self.body("tool", fetch=FakeGitHub(fail=True)))

    def test_release_notes_are_inert_text_and_cut_short(self):
        self.github_tool("1.2.0", "1.3.0")
        notes = ("Thanks @someone <img src=x onerror=alert(1)>\n" + "`" * 300 + "\n# not a heading\n"
                 + "\n".join(f"line {i}" for i in range(100)))
        body = self.body("tool", fetch=FakeGitHub(release("owner/tool", "v1.3.0", body=notes)))
        block = body.split("<summary>Release notes for v1.3.0</summary>", 1)[1].split("</details>", 1)[0]
        code = [line for line in block.split("\n") if line.startswith("    ")]
        self.assertEqual(code[0], "    Thanks @someone <img src=x onerror=alert(1)>")
        self.assertEqual(code[1], "    " + "`" * 300, "a backtick run stays inside the indented block")
        self.assertEqual(code[2], "    # not a heading")
        self.assertNotIn("```", block.replace("`" * 300, ""), "no fence that notes could close")
        self.assertNotIn("line 99", block)
        self.assertIn("[Full release notes](https://github.com/owner/tool/releases/tag/v1.3.0)", block)

    def test_release_tags_are_escaped_in_the_summary(self):
        self.github_tool("1.2.0", "1.3.0")
        data = release("owner/tool", "v1.3.0", body="notes")
        next(iter(data.values()))["tag_name"] = "<b>v1.3.0</b>"
        body = self.body("tool", fetch=FakeGitHub(data))
        self.assertIn("<summary>Release notes for &lt;b&gt;v1.3.0&lt;/b&gt;</summary>", body)

    def test_semver_jumps_are_labelled_and_other_versions_are_not(self):
        cases = [("1.2.0", "2.0.0", " (major)"), ("1.2.0", "1.3.0", " (minor)"), ("1.2.0", "1.2.1", " (patch)"),
                 ("2026.10.4", "2026.11.0", " (minor)"), ("0.0.1795622439", "0.0.1795636836", " (patch)"),
                 ("4.0.0.r8367.gd4512a7", "4.0.0.r8368.gf767c7a", "")]
        for old, new, label in cases:
            with self.subTest(old=old, new=new):
                self.assertEqual(m.change_label(old, new), label)

    def test_git_tags_off_github_link_the_tags_and_ask_nothing_online(self):
        self.repo.write("tool", recipe("1.0", body='source=("https://gitlab.freedesktop.org/x/tool/-/archive/v${pkgver}/tool-v${pkgver}.tar.gz")\n'
                                                     f"sha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "upstream": {"watch": {"git_tags": "https://gitlab.freedesktop.org/x/tool.git", "pattern": r"v(?P<version>[0-9.]+)"}}})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body='source=("https://gitlab.freedesktop.org/x/tool/-/archive/v${pkgver}/tool-v${pkgver}.tar.gz")\n'
                                                     f"sha256sums=('{SHA['b']}')\n"))
        fetch = FakeGitHub()
        body = self.body("tool", fetch=fetch)
        self.assertIn("| Source | Tags of [gitlab.freedesktop.org/x/tool](https://gitlab.freedesktop.org/x/tool.git) |", body)
        self.assertIn("| all | [`tool-v1.1.tar.gz`](https://gitlab.freedesktop.org/x/tool/-/archive/v1.1/tool-v1.1.tar.gz) | sha256 `aaaaaaaa…` → `bbbbbbbb…` |", body)
        self.assertNotIn("| Changes |", body)
        self.assertEqual(fetch.calls, [])

    def test_git_tags_on_github_link_the_tag_compare(self):
        self.repo.write("tool", recipe("0.1", body='source=("$pkgname-$pkgver.tar.gz::https://github.com/birkskyum/tool/archive/v$pkgver.tar.gz")\n'
                                                     f"sha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "upstream": {"watch": {"git_tags": "https://github.com/birkskyum/tool.git", "pattern": r"v(?P<version>[0-9.]+)"}}})
        self.repo.commit()
        self.repo.write("tool", recipe("0.2", body='source=("$pkgname-$pkgver.tar.gz::https://github.com/birkskyum/tool/archive/v$pkgver.tar.gz")\n'
                                                     f"sha256sums=('{SHA['b']}')\n"))
        body = self.body("tool", fetch=FakeGitHub())
        self.assertIn("| Source | Tags of [birkskyum/tool](https://github.com/birkskyum/tool/tags) |", body)
        self.assertIn("| Changes | [`v0.1...v0.2`](https://github.com/birkskyum/tool/compare/v0.1...v0.2) |", body)
        self.assertIn("| Tag | [`v0.2`](https://github.com/birkskyum/tool/tree/v0.2) |", body)

    def test_a_branch_tip_links_the_commit_range_and_never_asks_for_a_release(self):
        old, new = "d4512a7559f7d96711fedeb1f4c4fd368b51de22", "f767c7a6ceec2f5d1d8f533c69e341e2dedd3b1d"
        source = 'source=("omarchy-$_commit.tar.gz::https://github.com/basecamp/omarchy/archive/$_commit.tar.gz")\n'
        self.repo.write("omarchy-dev", recipe("4.0.0.r8367.gd4512a7", arch="('any')", body=f"_commit={old}\n{source}sha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "upstream": {"watch": {"git_branch": "https://github.com/basecamp/omarchy.git", "branch": "dev", "tag_pattern": "v(?P<version>.*)"}}})
        self.repo.commit()
        self.repo.write("omarchy-dev", recipe("4.0.0.r8368.gf767c7a", arch="('any')", body=f"_commit={new}\n{source}sha256sums=('{SHA['b']}')\n"))
        fetch = FakeGitHub()
        body = self.body("omarchy-dev", fetch=fetch)
        self.assertIn("| Source | Branch `dev` of [basecamp/omarchy](https://github.com/basecamp/omarchy/tree/dev) |", body)
        self.assertIn(f"| Changes | [`d4512a7559f7...f767c7a6ceec`](https://github.com/basecamp/omarchy/compare/{old}...{new}) |", body)
        self.assertIn(f"| Pinned | `_commit` `{old[:12]}` → `{new[:12]}` |", body)
        self.assertIn("| Arches | any (x86_64 and aarch64) |", body)
        self.assertEqual(fetch.calls, [])

    def test_each_feed_provider_names_its_feed(self):
        cases = [
            ({"npm": "@playwright/cli", "dist_tag": "next"}, "npm package [@playwright/cli](https://www.npmjs.com/package/@playwright/cli), dist-tag `next`"),
            ({"npm": "tool"}, "npm package [tool](https://www.npmjs.com/package/tool)"),
            ({"pypi": "terminaltexteffects"}, "PyPI project [terminaltexteffects](https://pypi.org/project/terminaltexteffects/)"),
            ({"debian": "https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages", "package": "1password"},
             "Debian package `1password` in [downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages](https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages)"),
            ({"json": "https://product-details.mozilla.org/1.0/firefox_versions.json", "path": "LATEST_FIREFOX_VERSION"},
             "JSON feed [product-details.mozilla.org/1.0/firefox_versions.json](https://product-details.mozilla.org/1.0/firefox_versions.json)"),
            ({"regex": "https://antigravity.google/download/", "pattern": "x"}, "Page [antigravity.google/download](https://antigravity.google/download/)"),
            ({"redirect": "https://www.dropbox.com/download?plat=lnx.x86_64", "pattern": "x"},
             "Download redirect [www.dropbox.com/download?plat=lnx.x86_64](https://www.dropbox.com/download?plat=lnx.x86_64)"),
            ({"archive": "https://example.test/app.deb", "pattern": "x"}, "Metadata inside [example.test/app.deb](https://example.test/app.deb)"),
        ]
        for watch, expected in cases:
            with self.subTest(watch=watch):
                self.assertEqual(m.source_label({"source": "local", "upstream": {"watch": watch}}, has_hook=False), expected)

    def test_declarative_providers_hooks_and_rebuilds_name_their_source(self):
        cases = [
            ({"upstream": {"github": "omacom/omarchy-billboard-generator", "assets": {}}, "has_hook": False},
             "GitHub releases of [omacom/omarchy-billboard-generator](https://github.com/omacom/omarchy-billboard-generator/releases)"),
            ({"upstream": {"git_tags": "https://github.com/hyprwm/Hyprland.git", "tag_pattern": "v{pkgver}"}, "has_hook": False},
             "Tags of [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland/tags)"),
            ({"upstream": {"npm": "@openai/codex", "sources": {}}, "has_hook": False},
             "npm package [@openai/codex](https://www.npmjs.com/package/@openai/codex)"),
            ({"upstream": {"debian": "https://downloads.claude.ai/Packages", "package": "claude-desktop", "sources": {}}, "has_hook": False},
             "Debian package `claude-desktop` in [downloads.claude.ai/Packages](https://downloads.claude.ai/Packages)"),
            ({"has_hook": True}, "Custom check in `.omarchy/upstream.sh`"),
            ({"rebuild_on": ["hyprland"], "has_hook": False}, "Rebuild when a dependency moves (`rebuild_on`)"),
            ({"has_hook": False}, "No upstream declared"),
        ]
        for spec_, expected in cases:
            has_hook = spec_.pop("has_hook")
            with self.subTest(expected=expected):
                self.assertEqual(m.source_label({"source": "local", **spec_}, has_hook=has_hook), expected)

    def test_a_declarative_github_release_is_looked_up_like_a_watched_one(self):
        self.github_tool("1.2.0", "1.3.0", metadata={"source": "local", "upstream": {"github": "owner/tool", "assets": {}, "digests": True}})
        body = self.body("tool", fetch=FakeGitHub(release("owner/tool", "v1.3.0")))
        self.assertIn("| Release | [v1.3.0](https://github.com/owner/tool/releases/tag/v1.3.0), published 2026-11-19 |", body)

    def test_a_hook_package_still_shows_its_version_sources_and_policy(self):
        self.repo.write("cua", recipe("1.0", arch="('x86_64')", body=f"source=(\"https://cua.test/cua-$pkgver.zip\")\nsha256sums=('{SHA['a']}')\n"),
                        {"source": "local"}, files={".omarchy/upstream.sh": "echo {}\n"})
        self.repo.commit()
        self.repo.write("cua", recipe("1.1", arch="('x86_64')", body=f"source=(\"https://cua.test/cua-$pkgver.zip\")\nsha256sums=('{SHA['b']}')\n"))
        body = self.body("cua", fetch=FakeGitHub())
        self.assertIn("Updates **cua** from `1.0-1` to `1.1-1` (minor).", body)
        self.assertIn("| Source | Custom check in `.omarchy/upstream.sh` |", body)
        self.assertIn("| all | [`cua-1.1.zip`](https://cua.test/cua-1.1.zip) | sha256 `aaaaaaaa…` → `bbbbbbbb…` |", body)

    def test_a_rebuild_names_the_dependencies_that_moved(self):
        meta = {"source": "local", "rebuild_on": ["hyprland", "aquamarine"],
                "rebuilt_against": {"x86_64": {"hyprland": "0.57.2-4", "aquamarine": "0.16.0-1"}, "aarch64": {"hyprland": "0.57.2-4", "aquamarine": "0.16.0-1"}}}
        self.repo.write("omareel", recipe("0.5.0", pkgrel="4", body=f"source=(\"x.tar.gz\")\nsha256sums=('{SHA['a']}')\n"), meta, files={"x.tar.gz": ""})
        self.repo.commit()
        meta["rebuilt_against"]["x86_64"]["hyprland"] = meta["rebuilt_against"]["aarch64"]["hyprland"] = "0.57.2-5"
        self.repo.write("omareel", recipe("0.5.0", pkgrel="5", body=f"source=(\"x.tar.gz\")\nsha256sums=('{SHA['a']}')\n"), meta)
        body = self.body("omareel", fetch=FakeGitHub())
        self.assertIn("Rebuilds **omareel** from `0.5.0-4` to `0.5.0-5` against updated dependencies.", body)
        self.assertIn("| Rebuilt against | `hyprland` `0.57.2-4` → `0.57.2-5` (x86_64, aarch64) |", body)
        self.assertIn("| Verification | same sources and checksums as before |", body)
        self.assertNotIn("aquamarine", body)
        self.assertNotIn("**Sources**", body)

    def test_a_lockstep_group_summarises_then_details_each_package(self):
        for name in ("omarchy-dev", "omarchy-settings-dev"):
            self.repo.write(name, recipe("4.0.0.r1.g1", arch="('any')", body=f"source=(\"https://example.test/{name}-$pkgver.tar.gz\")\nsha256sums=('{SHA['a']}')\n"),
                            {"source": "local", "upstream": {"watch": {"git_branch": "https://github.com/basecamp/omarchy.git", "branch": "dev"}}})
        self.repo.commit()
        for name in ("omarchy-dev", "omarchy-settings-dev"):
            self.repo.write(name, recipe("4.0.0.r2.g2", arch="('any')", body=f"source=(\"https://example.test/{name}-$pkgver.tar.gz\")\nsha256sums=('{SHA['b']}')\n"))
        body = self.body("omarchy-dev", "omarchy-settings-dev", fetch=FakeGitHub())
        self.assertIn("Updates 2 packages together.", body)
        self.assertIn("| Package | From | To |\n|---|---|---|\n| omarchy-dev | `4.0.0.r1.g1-1` | `4.0.0.r2.g2-1` |\n| omarchy-settings-dev | `4.0.0.r1.g1-1` | `4.0.0.r2.g2-1` |", body)
        self.assertEqual(body.count("\n### "), 2)
        self.assertIn("\n### omarchy-dev\n", body)

    def test_channels_follow_the_release_ring(self):
        cases = [({"release_ring": "fast"}, "edge, rc and stable (fast ring)"),
                 ({}, "edge; rc and stable by promotion"),
                 ({"pinned": True}, "edge; rc only through a release candidate")]
        for meta, expected in cases:
            with self.subTest(meta=meta):
                self.assertEqual(m.ships_to({"source": "local", **meta}), expected)

    def test_policy_follows_review(self):
        self.github_tool("1.2.0", "1.3.0")
        self.assertIn("Auto-merges once `result`, `self-tests` and `build-isolation` pass.", self.body("tool"))
        reviewed = self.body("tool", review=True)
        self.assertIn("Opened as a draft: a package in it is marked `review`.", reviewed)
        self.assertNotIn("Auto-merges once", reviewed)

    def test_pgp_keys_and_skipped_checksums_are_reported(self):
        self.repo.write("tool", recipe("1.0", body='source=("https://example.test/t-$pkgver.tar.gz" "https://example.test/t-$pkgver.tar.gz.sig")\n'
                                                     "sha256sums=('" + SHA["a"] + "' 'SKIP')\nvalidpgpkeys=('AAAA' 'BBBB')\n"),
                        {"source": "local", "upstream": {"watch": {"regex": "https://example.test/", "pattern": "x"}}})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body='source=("https://example.test/t-$pkgver.tar.gz" "https://example.test/t-$pkgver.tar.gz.sig")\n'
                                                     "sha256sums=('" + SHA["b"] + "' 'SKIP')\nvalidpgpkeys=('AAAA' 'BBBB')\n"))
        body = self.body("tool")
        self.assertIn("| Verification | checksums recorded by the sync; `validpgpkeys` pins 2 keys for the signed sources makepkg checks |", body)
        self.assertIn("| all | [`t-1.1.tar.gz.sig`](https://example.test/t-1.1.tar.gz.sig) | sha256 `SKIP` |", body)

    def test_pinned_variables_and_the_hidden_record(self):
        self.repo.write("ag", recipe("2.35.1", body="_build=4615540875067392\n" + f"source=(\"https://dl.test/$_build/a.deb\")\nsha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "release_ring": "fast", "min_release_age": "2d",
                         "upstream": {"watch": {"regex": "https://antigravity.google/download/", "pattern": "x", "variables": {"_build": "{build}"}}}})
        self.repo.commit()
        self.repo.write("ag", recipe("2.35.2", body="_build=4585983447007232\n" + f"source=(\"https://dl.test/$_build/a.deb\")\nsha256sums=('{SHA['b']}')\n"))
        body = self.body("ag")
        self.assertIn("| Pinned | `_build` `4615540875067392` → `4585983447007232` |", body)
        self.assertIn("| Ships to | edge, rc and stable (fast ring) |", body)
        self.assertIn("| Minimum release age | 2d |", body)
        record = hidden(body)
        self.assertEqual(record["packages"][0]["name"], "ag")
        self.assertEqual((record["packages"][0]["before"], record["packages"][0]["after"]), ("2.35.1-1", "2.35.2-1"))
        self.assertEqual(record["packages"][0]["source"]["kind"], "regex")
        self.assertNotIn("-->", body.split("<!-- omarchy-sync-pr ", 1)[1][:-5])

    def test_pinned_shows_only_the_lines_the_sync_rewrote(self):
        text = '_build={b}\n_dl="https://dl.test/${{pkgver}}-${{_build}}"\nsource=("$_dl/a.deb")\nsha256sums=(\'{s}\')\n'
        self.repo.write("ag", recipe("2.35.1", body=text.format(b="111", s=SHA["a"])),
                        {"source": "local", "upstream": {"watch": {"regex": "https://ag.test/", "pattern": "x"}}})
        self.repo.commit()
        self.repo.write("ag", recipe("2.35.2", body=text.format(b="222", s=SHA["b"])))
        body = self.body("ag")
        self.assertIn("| Pinned | `_build` `111` → `222` |", body)
        self.assertNotIn("_dl", body)

    def test_a_rebuild_asks_for_no_release(self):
        self.github_tool("1.2.0", "1.2.0", new_sums=("a", "b"))
        path = self.repo.root / "pkgbuilds/tool/PKGBUILD"
        path.write_text(path.read_text().replace("pkgrel=1", "pkgrel=2"))
        fetch = FakeGitHub(release("owner/tool", "v1.2.0", body="old notes"))
        body = self.body("tool", fetch=fetch)
        self.assertIn("Rebuilds **tool** from `1.2.0-1` to `1.2.0-2`.", body)
        self.assertEqual(fetch.calls, [])
        self.assertNotIn("| Release |", body)
        self.assertNotIn("| Tag |", body)
        self.assertNotIn("old notes", body)

    def test_release_notes_are_cut_at_a_line_boundary(self):
        self.github_tool("1.2.0", "1.3.0")
        notes = "\n".join(f"{i:03d} " + "x" * 300 for i in range(30))
        body = self.body("tool", fetch=FakeGitHub(release("owner/tool", "v1.3.0", body=notes)))
        shown = [line[4:] for line in body.split("\n") if line.startswith("    ")]
        self.assertTrue(shown and all(len(line) == 304 for line in shown), "every line shown is whole")
        self.assertLess(sum(len(line) + 1 for line in shown), 4001)

    def test_release_notes_cannot_spoof_the_record(self):
        self.github_tool("1.2.0", "1.3.0")
        fake = '<!-- omarchy-sync-pr {"packages":[{"name":"evil"}]} -->'
        body = self.body("tool", fetch=FakeGitHub(release("owner/tool", "v1.3.0", body=fake)))
        self.assertEqual(hidden(body)["packages"][0]["name"], "tool")
        self.assertTrue(body.rstrip().endswith("-->"))

    def test_a_github_source_of_another_project_is_not_shown_as_the_release(self):
        text = ('_electronver={e}\nsource=("https://slack.test/slack-$pkgver.deb"\n'
                '"https://github.com/electron/electron/releases/download/v$_electronver/electron-v$_electronver-linux-x64.zip")\n'
                "sha256sums=('{a}' '{b}')\n")
        self.repo.write("slack", recipe("4.40.0", arch="('x86_64')", body=text.format(e="38.0.0", a=SHA["a"], b=SHA["b"])),
                        {"source": "local", "upstream": {"watch": {"regex": "https://slack.test/", "pattern": "x"}}})
        self.repo.commit()
        self.repo.write("slack", recipe("4.41.0", arch="('x86_64')", body=text.format(e="38.1.0", a=SHA["c"], b=SHA["d"])))
        fetch = FakeGitHub()
        body = self.body("slack", fetch=fetch)
        self.assertNotIn("electron/electron/compare", body)
        self.assertNotIn("| Release |", body)
        self.assertNotIn("| Tag |", body)
        self.assertEqual(fetch.calls, [])
        self.assertIn("| Pinned | `_electronver` `38.0.0` → `38.1.0` |", body)

    def test_a_source_that_differs_per_arch_is_listed_per_arch(self):
        text = ('if [[ $CARCH == aarch64 ]]; then source=("https://dl.test/t-$pkgver-arm.tar.gz"); sha256sums=(\'{b}\');\n'
                'else source=("https://dl.test/t-$pkgver-x64.tar.gz"); sha256sums=(\'{a}\'); fi\n')
        self.repo.write("tool", recipe("1.0", body=text.format(a=SHA["a"], b=SHA["b"])),
                        {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body=text.format(a=SHA["c"], b=SHA["d"])))
        body = self.body("tool")
        self.assertIn("| x86_64 | [`t-1.1-x64.tar.gz`](https://dl.test/t-1.1-x64.tar.gz) | sha256 `aaaaaaaa…` → `cccccccc…` |", body)
        self.assertIn("| aarch64 | [`t-1.1-arm.tar.gz`](https://dl.test/t-1.1-arm.tar.gz) | sha256 `bbbbbbbb…` → `dddddddd…` |", body)
        self.assertNotIn("| all |", body)

    def test_a_removed_source_is_listed(self):
        self.repo.write("tool", recipe("1.0", body=f"source=(\"https://dl.test/t-$pkgver.tar.gz\" \"fix.patch\")\nsha256sums=('{SHA['a']}' '{SHA['b']}')\n"),
                        {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}}, files={"fix.patch": ""})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body=f"source=(\"https://dl.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['c']}')\n"))
        self.assertIn("| all | `fix.patch` | removed |", self.body("tool"))

    def test_a_flat_rebuilt_against_reads_as_x86_64(self):
        self.repo.write("plug", recipe("1.0", pkgrel="1", arch="('x86_64' 'aarch64')", body=f"source=(\"x\")\nsha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "rebuild_on": ["hyprland"], "rebuilt_against": {"hyprland": "0.57.2-4"}}, files={"x": ""})
        self.repo.commit()
        self.repo.write("plug", recipe("1.0", pkgrel="2", arch="('x86_64' 'aarch64')", body=f"source=(\"x\")\nsha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "rebuild_on": ["hyprland"],
                         "rebuilt_against": {"x86_64": {"hyprland": "0.57.2-5"}, "aarch64": {"hyprland": "0.57.2-5"}}})
        body = self.body("plug")
        self.assertIn("`hyprland` `0.57.2-4` → `0.57.2-5` (x86_64)", body)
        self.assertIn("`hyprland` `unrecorded` → `0.57.2-5` (aarch64)", body)
        self.repo.write("plug", metadata={"source": "local", "rebuild_on": ["hyprland"], "rebuilt_against": {"hyprland": "0.57.2-6"}})
        self.assertIn("`hyprland` `0.57.2-4` → `0.57.2-6` (x86_64)", self.body("plug"))

    def test_link_targets_cannot_break_the_link_or_the_table(self):
        self.assertEqual(m.link("a|b", "https://x.test/a|b c)d"), "[a\\|b](https://x.test/a%7Cb%20c%29d)")

    def test_a_huge_group_stays_under_githubs_limit_and_keeps_its_record(self):
        names = [f"kernel-{i:02d}" for i in range(40)]
        for name in names:
            self.repo.write(name, recipe("1.0", body="".join(f'source_x86_64+=("https://dl.test/{name}-$pkgver-{j}.tar.gz")\n' for j in range(40))
                                         + "sha256sums_x86_64=(" + " ".join(f"'{SHA['a']}'" for _ in range(40)) + ")\n"),
                            {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}})
        self.repo.commit()
        for name in names:
            self.repo.write(name, recipe("1.1", body="".join(f'source_x86_64+=("https://dl.test/{name}-$pkgver-{j}.tar.gz")\n' for j in range(40))
                                         + "sha256sums_x86_64=(" + " ".join(f"'{SHA['b']}'" for _ in range(40)) + ")\n"))
        body = self.body(*names)
        self.assertLessEqual(len(body.encode("utf-16-le")) // 2, 65000)
        self.assertEqual([p["name"] for p in hidden(body)["packages"]], names)

    def test_a_tag_that_carries_the_version_after_a_v_counts_and_a_longer_version_does_not(self):
        self.repo.write("codex", recipe("0.171.0", body='source_x86_64=("https://github.com/openai/codex/releases/download/rust-v$pkgver/codex-x86_64.tar.gz")\n'
                                                      f"sha256sums_x86_64=('{SHA['a']}')\n"),
                        {"source": "local", "upstream": {"npm": "@openai/codex", "sources": {}}})
        self.repo.commit()
        self.repo.write("codex", recipe("0.172.0", body='source_x86_64=("https://github.com/openai/codex/releases/download/rust-v$pkgver/codex-x86_64.tar.gz")\n'
                                                      f"sha256sums_x86_64=('{SHA['b']}')\n"))
        body = self.body("codex", fetch=FakeGitHub(release("openai/codex", "rust-v0.172.0")))
        self.assertIn("| Release | [rust-v0.172.0](https://github.com/openai/codex/releases/tag/rust-v0.172.0), published 2026-11-19 |", body)
        self.assertIn("compare/rust-v0.171.0...rust-v0.172.0", body)
        self.assertTrue(m.carries_version("v1.2", "1.2"))
        self.assertFalse(m.carries_version("release-1.2.3", "1.2"))
        self.assertFalse(m.carries_version("v11.2", "1.2"))

    def test_a_source_removed_from_the_middle_is_the_one_listed(self):
        text = "source=({urls})\nsha256sums=({sums})\n"
        self.repo.write("tool", recipe("1.0", body=text.format(urls='"old.patch" "https://dl.test/t-$pkgver.tar.gz"', sums=f"'{SHA['a']}' '{SHA['b']}'")),
                        {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}}, files={"old.patch": ""})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body=text.format(urls='"https://dl.test/t-$pkgver.tar.gz"', sums=f"'{SHA['c']}'")))
        body = self.body("tool")
        self.assertIn("| all | `old.patch` | removed |", body)
        self.assertIn("| all | [`t-1.1.tar.gz`](https://dl.test/t-1.1.tar.gz) | sha256 `bbbbbbbb…` → `cccccccc…` |", body)

    def test_a_checksum_that_becomes_skip_is_a_change(self):
        self.repo.write("tool", recipe("1.0", body=f"source=(\"https://dl.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['a']}')\n"),
                        {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body="source=(\"https://dl.test/t-$pkgver.tar.gz\")\nsha256sums=('SKIP')\n"))
        body = self.body("tool")
        self.assertIn("| all | [`t-1.1.tar.gz`](https://dl.test/t-1.1.tar.gz) | sha256 `aaaaaaaa…` → `SKIP` |", body)
        self.assertIn("| Verification | checksums recorded by the sync; 1 changed source is not hashed (`SKIP`) |", body)

    def test_upstream_text_in_labels_and_code_stays_text(self):
        self.assertEqual(m.label("v1](https://evil.test) <b>*x*</b>"), "v1\\](https://evil.test) &lt;b&gt;\\*x\\*&lt;/b&gt;")
        self.assertEqual(m.code("a``b"), "```a``b```")
        self.assertEqual(m.code("`a"), "`` `a ``")
        self.github_tool("1.2.0", "1.3.0")
        data = release("owner/tool", "v1.3.0")
        next(iter(data.values()))["tag_name"] = "v1](https://evil.test"
        body = self.body("tool", fetch=FakeGitHub(data))
        self.assertIn("| Release | [v1\\](https://evil.test](https://github.com/owner/tool/releases/tag/v1.3.0), published 2026-11-19 |", body)

    def test_the_body_fits_even_when_notes_are_wide_characters(self):
        self.github_tool("1.2.0", "1.3.0")
        body = self.body("tool", fetch=FakeGitHub(release("owner/tool", "v1.3.0", body="\n".join("🦀" * 1000 for _ in range(40)))))
        self.assertLessEqual(len(body.encode("utf-16-le")) // 2, 65000)
        self.assertEqual(hidden(body)["packages"][0]["name"], "tool")

    def test_a_record_too_large_for_the_limit_keeps_only_names(self):
        sections = [{"name": f"p{i:04d}", "before": "1-1", "after": "2-1", "lead": "x", "summary": "", "sources": "", "notes": "",
                     "record": {"name": f"p{i:04d}", "blob": "y" * 500}} for i in range(200)]
        body = m.assemble_body(sections, review=False)
        self.assertLessEqual(len(body.encode("utf-16-le")) // 2, 65000)
        self.assertEqual([p["name"] for p in hidden(body)["packages"]], [f"p{i:04d}" for i in range(200)])

    def test_reordered_sources_pair_by_name_not_position(self):
        text = "source=({urls})\nsha256sums=({sums})\n"
        self.repo.write("tool", recipe("1.0", body=text.format(urls='"fix.patch" "https://dl.test/tool-$pkgver.tar.gz"', sums=f"'{SHA['a']}' '{SHA['b']}'")),
                        {"source": "local", "upstream": {"watch": {"regex": "https://dl.test/", "pattern": "x"}}}, files={"fix.patch": "", "extra.patch": ""})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body=text.format(urls='"https://dl.test/tool-$pkgver.tar.gz" "extra.patch"', sums=f"'{SHA['c']}' '{SHA['d']}'")))
        body = self.body("tool")
        self.assertIn("| all | [`tool-1.1.tar.gz`](https://dl.test/tool-1.1.tar.gz) | sha256 `bbbbbbbb…` → `cccccccc…` |", body)
        self.assertIn("| all | `fix.patch` | removed |", body)
        self.assertIn("| all | `extra.patch` | sha256 `dddddddd…` |", body)

    def test_a_release_pinned_by_commit_is_found_by_the_declared_tag_pattern(self):
        source = 'source=("sunshine-$_commit.tar.gz::https://github.com/LizardByte/Sunshine/archive/$_commit.tar.gz")\n'
        meta = {"source": "local", "upstream": {"watch": {"github": "LizardByte/Sunshine", "pattern": r"v(?P<version>[0-9]+(?:\.[0-9]+)*)",
                                                          "variables": {"_commit": "{commit}"}}}}
        self.repo.write("sunshine", recipe("2025.1", body=f"_commit={'1' * 40}\n{source}sha256sums=('{SHA['a']}')\n"), meta)
        self.repo.commit()
        self.repo.write("sunshine", recipe("2025.2", body=f"_commit={'2' * 40}\n{source}sha256sums=('{SHA['b']}')\n"))
        listing = {"https://api.github.com/repos/LizardByte/Sunshine/releases?per_page=100": [
            {"tag_name": "v2025.2", "draft": False}, {"tag_name": "nightly", "draft": False}, {"tag_name": "v2025.1", "draft": False}]}
        fetch = FakeGitHub({**listing, **release("LizardByte/Sunshine", "v2025.2")})
        body = self.body("sunshine", fetch=fetch)
        self.assertIn("| Release | [v2025.2](https://github.com/LizardByte/Sunshine/releases/tag/v2025.2), published 2026-11-19 |", body)
        self.assertIn("| Changes | [`v2025.1...v2025.2`](https://github.com/LizardByte/Sunshine/compare/v2025.1...v2025.2) |", body)
        offline = self.body("sunshine")
        self.assertIn(f"| Changes | [`{'1' * 12}...{'2' * 12}`](https://github.com/LizardByte/Sunshine/compare/{'1' * 40}...{'2' * 40}) |", offline)

    def test_git_tags_on_github_with_a_cdn_tarball_still_link_the_tags(self):
        source = 'source=("https://release.files.ghostty.org/$pkgver/ghostty-$pkgver.tar.gz")\n'
        meta = {"source": "local", "upstream": {"watch": {"git_tags": "https://github.com/ghostty-org/ghostty.git", "pattern": r"v(?P<version>[0-9]+(?:\.[0-9]+)*)"}}}
        self.repo.write("ghostty", recipe("1.1.0", body=f"{source}sha256sums=('{SHA['a']}')\n"), meta)
        self.repo.commit()
        self.repo.write("ghostty", recipe("1.2.0", body=f"{source}sha256sums=('{SHA['b']}')\n"))
        fetch = FakeGitHub({"https://api.github.com/repos/ghostty-org/ghostty/tags?per_page=100": [{"name": "tip"}, {"name": "v1.2.0"}, {"name": "v1.1.0"}]})
        body = self.body("ghostty", fetch=fetch)
        self.assertIn("| Tag | [`v1.2.0`](https://github.com/ghostty-org/ghostty/tree/v1.2.0) |", body)
        self.assertIn("| Changes | [`v1.1.0...v1.2.0`](https://github.com/ghostty-org/ghostty/compare/v1.1.0...v1.2.0) |", body)

    def test_declared_tags_for_declarative_providers(self):
        self.assertEqual(m.declared_tags({"upstream": {"git_tags": "https://github.com/hyprwm/Hyprland.git", "tag_pattern": "v{pkgver}"}},
                                         ["0.57.2"], None), {"0.57.2": "v0.57.2"})

    def test_each_download_links_to_where_its_bytes_come_from(self):
        self.repo.write("tool", recipe("1.0", body='source=("t-$pkgver.tar.gz::https://mirror-a.test/x/t.tar.gz" "fix.patch")\n'
                                                     f"sha256sums=('{SHA['a']}' '{SHA['b']}')\n"),
                        {"source": "local"}, files={".omarchy/upstream.sh": "echo {}\n", "fix.patch": ""})
        self.repo.commit()
        self.repo.write("tool", recipe("1.1", body='source=("t-$pkgver.tar.gz::https://mirror-b.test/y/t.tar.gz" "fix.patch")\n'
                                                     f"sha256sums=('{SHA['c']}' '{SHA['d']}')\n"), files={"fix.patch": "changed"})
        body = self.body("tool")
        self.assertIn("| all | [`t-1.1.tar.gz`](https://mirror-b.test/y/t.tar.gz) | sha256 `aaaaaaaa…` → `cccccccc…` |", body)
        self.assertIn("| all | `fix.patch` | sha256 `bbbbbbbb…` → `dddddddd…` |", body)

    def test_table_cells_cannot_break_the_table(self):
        self.assertEqual(m.cell("a|b\nc"), "a\\|b c")


class CliTest(unittest.TestCase):
    def test_prints_the_body_for_the_working_tree_change(self):
        repo = Repo(self)
        repo.write("tool", recipe("1.0", body=f"source=(\"https://example.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['a']}')\n"),
                   {"source": "local", "upstream": {"watch": {"regex": "https://example.test/", "pattern": "x"}}})
        repo.commit()
        repo.write("tool", recipe("1.1", body=f"source=(\"https://example.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['b']}')\n"))
        result = subprocess.run([sys.executable, str(SCRIPT), "--offline", "tool"], cwd=repo.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Updates **tool** from `1.0-1` to `1.1-1` (minor).", result.stdout)

    def test_recipes_never_see_the_token(self):
        repo = Repo(self)
        leak = "printf %s \"${UPSTREAM_GITHUB_TOKEN-}${GH_TOKEN-}\" >> \"$PWD/leak\"\n"
        repo.write("tool", recipe("1.0", body=leak + f"source=(\"https://example.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['a']}')\n"),
                   {"source": "local", "upstream": {"watch": {"regex": "https://example.test/", "pattern": "x"}}})
        repo.commit()
        repo.write("tool", recipe("1.1", body=leak + f"source=(\"https://example.test/t-$pkgver.tar.gz\")\nsha256sums=('{SHA['b']}')\n"))
        env = {"PATH": "/usr/bin:/bin", "UPSTREAM_GITHUB_TOKEN": "secret-token", "GH_TOKEN": "other-token"}
        result = subprocess.run([sys.executable, str(SCRIPT), "--offline", "tool"], cwd=repo.root, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("token", (repo.root / "pkgbuilds/tool/leak").read_text())

    def test_fails_without_packages(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--offline"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
