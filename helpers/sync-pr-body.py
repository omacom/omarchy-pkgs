#!/usr/bin/env python3
"""Write the description of a sync PR from the change it carries.

package-prs.yml runs this in a job of its own, with no credential that can
write, after it applies one group's recipes to the working tree. For each
package it compares the recipe and .omarchy/package.json at --base with the
working tree, and prints Markdown: what moved, where it came from, what was
recorded, and where it ships. Every source type gets the same facts, because
they come from the change itself.

Reading a recipe means sourcing it in bash, so recipes run with an empty
environment, and the job that runs this holds only a read-only token: the jobs
that push and arm auto-merge never run recipe code. Where the package's own upstream
is a tag on GitHub, the release's link, date, notes and asset digests come from
GitHub's API, unless --offline is given or the lookup fails.

Release notes are upstream's text: they go into an indented code block, which
nothing in them can close, so they render as inert text, mention nobody and
run no HTML. A hidden comment at the end repeats the facts as JSON.
"""
import argparse
import difflib
import html
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import quote, unquote, urlsplit

_spec = importlib.util.spec_from_file_location("upstream_watch", Path(__file__).resolve().parent / "upstream-watch.py")
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)

ARCHES = ("x86_64", "aarch64")
NOTES_LINES = 40
NOTES_CHARS = 4000
# GitHub refuses a PR body over 65,536 UTF-16 code units, and the PR action
# truncates at that length. Stay under it so the record at the end survives.
BODY_LIMIT = 65000
RECIPE_TIMEOUT = 30
COMMIT = re.compile(r"[0-9a-f]{40}")
ARCHIVE = r"\.(?:tar\.gz|tar\.bz2|tar\.xz|tar\.zst|tgz|zip)"
TOKENS = ("UPSTREAM_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")
AUTO_MERGE = ("Auto-merges once `result`, `self-tests` and `build-isolation` pass. "
              "A failing build leaves it open for a maintainer without holding back any other package.")
REVIEW = ("Opened as a draft: a package in it is marked `review`. "
          "A maintainer reads it and marks it ready, and it lands once green.")
DUMP = watch.DUMP


def utf16(text):
    return len(text.encode("utf-16-le")) // 2


def cell(text):
    """Keep a value inside its table cell."""
    return str(text).replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def code(text):
    """An inline code span no backtick in the text can close."""
    text = cell(text)
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * (longest + 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return f"{fence}{pad}{text}{pad}{fence}"


def label(text):
    """Link text from upstream: no brackets, emphasis, code or HTML of its own."""
    text = cell(str(text).replace("\\", "\\\\"))
    text = text.replace("<", "&lt;").replace(">", "&gt;")
    # Brackets end the link, * and ` change its text; _ and ~ only restyle it.
    for char in "[]*`":
        text = text.replace(char, "\\" + char)
    return text


def destination(url):
    """A link target that cannot end the link, the cell or the line early."""
    for char, encoded in (("|", "%7C"), (" ", "%20"), ("(", "%28"), (")", "%29"), ("<", "%3C"), (">", "%3E"),
                          ("\n", ""), ("\r", "")):
        url = url.replace(char, encoded)
    return url


def link(text, url):
    return f"[{label(text)}]({destination(url)})"


def short(value):
    """Long hashes are shown by their first characters; versions stay whole."""
    if COMMIT.fullmatch(value):
        return value[:12]
    if re.fullmatch(r"[0-9a-f]{32,}", value):
        return value[:8] + "…"
    return value


def display(url):
    parts = urlsplit(url)
    text = (parts.netloc + parts.path).rstrip("/")
    return text + (f"?{parts.query}" if parts.query else "")


def github_repo(url):
    found = re.fullmatch(r"(?:git\+)?https://github\.com/([^/]+)/([^/#?]+?)(?:\.git)?/?", url or "")
    return f"{found[1]}/{found[2]}" if found else None


def github_ref(source):
    """(owner/repo, "tag" or "commit", ref) for a source on GitHub, else None."""
    url = source.split("::", 1)[1] if "::" in source else source
    url = url.removeprefix("git+")
    parts = urlsplit(url)
    host, path = parts.hostname or "", parts.path
    if host == "github.com":
        repo = re.fullmatch(r"/([^/]+)/([^/]+?)(?:\.git)?/?", path)
        if repo and parts.fragment:
            kind, _, ref = parts.fragment.partition("=")
            return (f"{repo[1]}/{repo[2]}", kind, unquote(ref)) if kind in ("tag", "commit") and ref else None
        # A release asset always names a tag, however its name looks.
        found = re.fullmatch(r"/([^/]+)/([^/]+)/releases/download/([^/]+)/[^/]+", path)
        if found:
            return (f"{found[1]}/{found[2]}", "tag", unquote(found[3]))
        if re.fullmatch(rf"/[^/]+/[^/]+/archive/refs/heads/.+{ARCHIVE}", path) or re.fullmatch(r"/[^/]+/[^/]+/raw/refs/heads/.+", path):
            return None
        found = (re.fullmatch(r"/([^/]+)/([^/]+)/raw/(?:refs/tags/)?([^/]+)/.+", path) or re.fullmatch(rf"/([^/]+)/([^/]+)/archive/refs/tags/(.+?){ARCHIVE}", path)
                 or re.fullmatch(rf"/([^/]+)/([^/]+)/archive/(.+?){ARCHIVE}", path))
    elif host == "codeload.github.com":
        if re.fullmatch(r"/[^/]+/[^/]+/(?:tar\.gz|zip|legacy\.tar\.gz)/refs/heads/.+", path):
            return None
        found = re.fullmatch(r"/([^/]+)/([^/]+)/(?:tar\.gz|zip|legacy\.tar\.gz)/(?:refs/tags/)?(.+)", path)
    elif host == "raw.githubusercontent.com":
        if "/refs/heads/" in path:
            return None
        found = re.fullmatch(r"/([^/]+)/([^/]+)/(?:refs/tags/)?([^/]+)/.+", path)
    else:
        return None
    if not found:
        return None
    ref = unquote(found[3])
    return (f"{found[1]}/{found[2]}", "commit" if COMMIT.fullmatch(ref) else "tag", ref)


def change_label(old, new):
    pattern = r"(\d+)\.(\d+)(?:\.(\d+))?"
    a, b = re.fullmatch(pattern, old), re.fullmatch(pattern, new)
    if not (a and b):
        return ""
    for index, name in enumerate(("major", "minor", "patch"), 1):
        if (a[index] or "0") != (b[index] or "0"):
            return f" ({name})"
    return ""


def upstream_spec(meta):
    """The provider name, its settings, and whether it is declared directly."""
    upstream = meta.get("upstream")
    if isinstance(upstream, dict) and isinstance(upstream.get("watch"), dict):
        spec, declarative = upstream["watch"], False
    elif isinstance(upstream, dict):
        spec, declarative = upstream, True
    else:
        return None, {}, False
    kind = next((name for name in sorted(watch.PROVIDERS) if name in spec), None)
    return kind, spec, declarative


def declared_repo(meta):
    """The GitHub repository the package's upstream declaration names, if any."""
    kind, spec, _ = upstream_spec(meta)
    if kind == "github":
        return spec["github"]
    if kind in ("git_tags", "git_branch"):
        return github_repo(spec[kind])
    return None


def source_label(meta, has_hook):
    kind, spec, _ = upstream_spec(meta)
    if kind == "github":
        repo = spec["github"]
        return f"GitHub releases of {link(repo, 'https://github.com/' + repo + '/releases')}"
    if kind in ("git_tags", "git_branch"):
        url = spec[kind]
        repo = github_repo(url)
        if kind == "git_branch":
            branch = spec.get("branch", "")
            target = link(repo, f"https://github.com/{repo}/tree/{branch}") if repo else link(display(url).removesuffix(".git"), url)
            return f"Branch {code(branch)} of {target}"
        target = link(repo, f"https://github.com/{repo}/tags") if repo else link(display(url).removesuffix(".git"), url)
        return f"Tags of {target}"
    if kind == "npm":
        name = spec["npm"]
        tag = spec.get("dist_tag")
        suffix = f", dist-tag {code(tag)}" if tag and tag != "latest" else ""
        return f"npm package {link(name, 'https://www.npmjs.com/package/' + name)}{suffix}"
    if kind == "pypi":
        name = spec["pypi"]
        return f"PyPI project {link(name, 'https://pypi.org/project/' + name + '/')}"
    if kind == "debian":
        return f"Debian package {code(spec.get('package', ''))} in {link(display(spec['debian']), spec['debian'])}"
    labels = {"json": "JSON feed", "regex": "Page", "redirect": "Download redirect", "archive": "Metadata inside"}
    if kind in labels:
        return f"{labels[kind]} {link(display(spec[kind]), spec[kind])}"
    if has_hook:
        return "Custom check in `.omarchy/upstream.sh`"
    if meta.get("rebuild_on"):
        return "Rebuild when a dependency moves (`rebuild_on`)"
    return "No upstream declared"


def source_kind(meta, has_hook):
    kind, _, declarative = upstream_spec(meta)
    if kind:
        return {"kind": kind, "declarative": declarative}
    return {"kind": "hook" if has_hook else "rebuild" if meta.get("rebuild_on") else "none", "declarative": False}


def ships_to(meta):
    if meta.get("pinned") is True:
        return "edge; rc only through a release candidate"
    if meta.get("release_ring") == "fast":
        return "edge, rc and stable (fast ring)"
    return "edge; rc and stable by promotion"


def run_recipe(script, directory, arch, *args):
    """Source a recipe in bash with nothing from this process's environment."""
    with tempfile.TemporaryDirectory(prefix="recipe-read-") as work:
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": work, "LANG": "C.UTF-8", "CARCH": arch,
               "SRCDEST": work, "srcdir": work, "pkgdir": work}
        return subprocess.run(["bash", "-c", script, "_", str((directory / "PKGBUILD").resolve()), *args],
                              cwd=directory, env=env, capture_output=True, check=True, timeout=RECIPE_TIMEOUT).stdout


def read_recipe(directory, arch="x86_64"):
    data = run_recipe(DUMP, directory, arch).decode().split("\0")
    result, index = {}, 0
    while index < len(data) - 1:
        name, size = data[index:index + 2]
        index += 2
        result[name] = data[index:index + int(size)]
        index += int(size)
    return result


def pgp_key_count(directory):
    script = 'source "$1" >/dev/null || exit 1; printf %s "${#validpgpkeys[@]}"'
    return int(run_recipe(script, directory, "x86_64").decode() or 0)


def assignments(directory):
    """Literal `_name=value` lines: the scalars the sync rewrites in place."""
    found = re.findall(r"^(_[A-Za-z0-9_]+)=([^\n]*)$", (directory / "PKGBUILD").read_text(), re.M)
    return {name: value.strip().strip("\"'") for name, value in found}


def read_package(directory):
    """Recipe values per architecture, and the package metadata."""
    first = read_recipe(directory)
    arches = first.get("arch") or ["x86_64"]
    recipes = {arch: read_recipe(directory, "x86_64" if arch == "any" else arch) for arch in arches}
    meta_path = directory / ".omarchy/package.json"
    meta = json.loads(meta_path.read_text()) if meta_path.is_file() else {}
    return {"arches": arches, "recipes": recipes, "first": recipes[arches[0]], "meta": meta,
            "hook": (directory / ".omarchy/upstream.sh").is_file(), "pgp_keys": pgp_key_count(directory),
            "assignments": assignments(directory)}


def base_package(root, base, package, scratch):
    archive = subprocess.run(["git", "-C", str(root), "archive", "--format=tar", base, f"pkgbuilds/{package}"],
                             capture_output=True)
    if archive.returncode != 0:
        return None
    path = Path(scratch) / "base.tar"
    path.write_bytes(archive.stdout)
    with tarfile.open(path) as tar:
        tar.extractall(scratch, filter="data")
    return read_package(Path(scratch) / "pkgbuilds" / package)


def version(recipe):
    epoch = watch.scalar(recipe, "epoch")
    return f"{epoch + ':' if epoch else ''}{watch.scalar(recipe, 'pkgver')}-{watch.scalar(recipe, 'pkgrel')}"


def source_name(source):
    if "::" in source:
        return source.split("::", 1)[0]
    url = source.removeprefix("git+")
    return Path(urlsplit(url).path).name or url


def align(old_sources, new_sources, old_pkgver, new_pkgver):
    """Pairs (old index or None, new index or None), matching sources by name.

    A version bump renames each source, so names are compared with the old
    version swapped for the new one. Sources whose names still differ pair
    by position within the run of changes, as a bump that renames a file does.
    """
    def name(source, version):
        text = source_name(source)
        return text.replace(version, new_pkgver) if version else text
    olds = [name(source, old_pkgver) for source in old_sources]
    news = [name(source, None) for source in new_sources]
    pairs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, olds, news, autojunk=False).get_opcodes():
        common = min(i2 - i1, j2 - j1)
        pairs += [(i1 + k, j1 + k) for k in range(common)]
        pairs += [(i, None) for i in range(i1 + common, i2)]
        pairs += [(None, j) for j in range(j1 + common, j2)]
    return pairs


def arch_entries(arch, recipe, before):
    """Changed sources of one build: {key: [(url, name, checksums or None for removed)]}."""
    result = {}
    old_pkgver, new_pkgver = watch.scalar(before, "pkgver"), watch.scalar(recipe, "pkgver")
    for key in ("source", f"source_{arch}"):
        if key not in recipe and key not in before:
            continue
        suffix = key.removeprefix("source")
        sums = sorted({name for name in list(recipe) + list(before)
                       if watch.SUM.fullmatch(name) and (watch.SUM.fullmatch(name)[2] or "") == suffix})
        new_sources, old_sources = recipe.get(key, []), before.get(key, [])
        entries = []
        for i, j in align(old_sources, new_sources, old_pkgver, new_pkgver):
            if j is None:
                old = old_sources[i]
                entries.append((old.split("::", 1)[-1], source_name(old), None))
                continue
            source = new_sources[j]
            old_source = old_sources[i] if i is not None else None
            checksums = []
            for name in sums:
                after = recipe.get(name, [])
                previous = before.get(name, [])
                checksums.append((watch.SUM.fullmatch(name)[1], previous[i] if i is not None and i < len(previous) else "",
                                  after[j] if j < len(after) else ""))
            if source != old_source or any(b != a for _, b, a in checksums):
                entries.append((source.split("::", 1)[1] if "::" in source else source, source_name(source), checksums))
        if entries:
            result[key] = entries
    return result


def source_rows(old, new):
    """(label, url, name, checksums or None) for each changed or removed source."""
    per_arch = {}
    for arch, recipe in new["recipes"].items():
        before = (old["recipes"].get(arch) or old["first"]) if old else {}
        per_arch[arch] = arch_entries("x86_64" if arch == "any" else arch, recipe, before)
    rows = []
    common = [entries.get("source", []) for entries in per_arch.values()]
    shared = all(entries == common[0] for entries in common)
    if shared:
        rows += [("all", *entry) for entry in common[0]]
    for arch, entries in per_arch.items():
        label = "all" if arch == "any" else arch
        if not shared:
            rows += [(label, *entry) for entry in entries.get("source", [])]
        rows += [(label, *entry) for key, items in entries.items() if key != "source" for entry in items]
    return rows


def source_cell(url, name):
    """The file name, linked to where its bytes come from when that is a download."""
    target = url.removeprefix("git+")
    if urlsplit(target).scheme in ("https", "http"):
        return f"[{code(name)}]({destination(target)})"
    return code(name)


def checksum_text(checksums):
    if checksums is None:
        return "removed"
    parts = []
    for algorithm, before, after in checksums:
        if before and before != after:
            parts.append(f"{algorithm} {code(short(before))} → {code(short(after))}")
        else:
            parts.append(f"{algorithm} {code(short(after))}")
    return "<br>".join(parts) or "none"


def package_github(old, new):
    """The upstream's GitHub repository and the refs its sources moved between.

    Only a ref in the repository the upstream declaration names counts, or,
    without one, a tag that carries the new version: a recipe may also pin a
    GitHub release of another project, such as Electron, which is not this
    package's release.
    """
    repo_named = declared_repo(new["meta"])
    pkgver = watch.scalar(new["first"], "pkgver")
    candidates = []
    for arch, recipe in new["recipes"].items():
        before = (old["recipes"].get(arch) or old["first"]) if old else {}
        old_pkgver = watch.scalar(before, "pkgver")
        for key in ("source", f"source_{arch}"):
            previous_sources = before.get(key, [])
            pairs = align(previous_sources, recipe.get(key, []), old_pkgver, pkgver)
            for i, index in pairs:
                if index is None:
                    continue
                source = recipe[key][index]
                after = github_ref(source)
                if not after:
                    continue
                if repo_named:
                    if after[0].lower() != repo_named.lower():
                        continue
                elif not (after[1] == "tag" and carries_version(after[2], pkgver)):
                    continue
                previous = previous_sources[i] if i is not None else None
                before_ref = github_ref(previous) if previous else None
                moved = bool(before_ref) and before_ref[0] == after[0] and before_ref[2] != after[2]
                candidates.append((not moved, "/releases/download/" not in source, after, before_ref if moved else None))
    if not candidates:
        return None
    _, _, after, before_ref = sorted(candidates, key=lambda item: item[:2])[0]
    return {"repo": after[0], "kind": after[1], "new": after[2], "old": before_ref[2] if before_ref else None}


def carries_version(tag, pkgver):
    """Whether a tag names this exact version: v1.2 and rust-v1.2 do, v11.2 and 1.2.3 do not."""
    pattern = rf"(?:(?<![0-9A-Za-z.])|(?<![0-9A-Za-z])[vV]){re.escape(pkgver)}(?![0-9A-Za-z]|\.[0-9A-Za-z])"
    return bool(pkgver) and re.search(pattern, tag) is not None


def declared_tags(meta, versions, fetch_json):
    """The tags the upstream declaration maps these versions to, found the way the sync finds them.

    A recipe that pins a release by commit, or downloads it from a CDN, names
    no tag in its sources; the declaration still says which tag a version is.
    """
    kind, spec, declarative = upstream_spec(meta)
    found = {}
    if kind == "git_tags" and declarative and "{pkgver}" in spec.get("tag_pattern", ""):
        return {version: spec["tag_pattern"].replace("{pkgver}", version) for version in versions}
    repo = declared_repo(meta)
    if not repo or fetch_json is None or kind not in ("github", "git_tags"):
        return found
    try:
        if kind == "github":
            names = [r.get("tag_name") for r in fetch_json(f"https://api.github.com/repos/{repo}/releases?per_page=100") if not r.get("draft")]
        else:
            names = [t.get("name") for t in fetch_json(f"https://api.github.com/repos/{repo}/tags?per_page=100")]
    except Exception:
        return found
    for name in names:
        if not isinstance(name, str):
            continue
        if declarative:
            version = name[1:] if name[:1] in "vV" else name
            if version in versions:
                found.setdefault(version, name)
            continue
        try:
            for item in watch.matches(spec, name, {"tag": name}, full=True):
                if item["pkgver"] in versions:
                    found.setdefault(item["pkgver"], name)
        except (ValueError, KeyError, IndexError, re.error):
            continue
    return found


def fetch_release(github, fetch_json):
    if not github or github["kind"] != "tag" or fetch_json is None:
        return None
    try:
        data = fetch_json(f"https://api.github.com/repos/{github['repo']}/releases/tags/{quote(github['new'], safe='')}")
    except Exception:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("html_url"), str) or not data["html_url"].startswith("https://github.com/"):
        return None
    return data


def per_arch(record):
    """rebuilt_against by architecture; the flat form predates it and meant x86_64."""
    if not isinstance(record, dict):
        return {}
    if record and all(isinstance(value, str) for value in record.values()):
        return {"x86_64": record}
    return {arch: deps for arch, deps in record.items() if isinstance(deps, dict)}


def rebuilt_rows(old_meta, new_meta):
    moved = {}
    before = per_arch(old_meta.get("rebuilt_against"))
    for arch, deps in per_arch(new_meta.get("rebuilt_against")).items():
        for dep, value in deps.items():
            previous = (before.get(arch) or {}).get(dep)
            if previous != value:
                moved.setdefault((dep, previous or "unrecorded", value), []).append(arch)
    order = {arch: index for index, arch in enumerate(ARCHES)}
    return [f"{code(dep)} {code(a)} → {code(b)} ({', '.join(sorted(arches, key=lambda x: order.get(x, 9)))})"
            for (dep, a, b), arches in sorted(moved.items())]


def verification(rows, release, new):
    """What the recorded change says about the new bytes, and nothing more."""
    transitions = [(url, algorithm, before, after) for _, url, _, checksums in rows if checksums
                   for algorithm, before, after in checksums if before != after]
    hashed = [(url, algorithm, after) for url, algorithm, before, after in transitions if after != "SKIP"]
    skipped = sum(1 for _, _, before, after in transitions if after == "SKIP")
    if not rows:
        parts = ["same sources and checksums as before"]
    elif not transitions:
        parts = ["no checksum changed"]
    else:
        digests = {}
        for asset in (release or {}).get("assets", []):
            digest = asset.get("digest") or ""
            if digest.startswith("sha256:"):
                digests[asset.get("browser_download_url")] = digest[7:]
        if hashed and digests and all(algorithm == "sha256" and digests.get(url) == after for url, algorithm, after in hashed):
            parts = ["sha256 of each changed checksum matches the digest GitHub lists for its asset"]
        else:
            parts = ["checksums recorded by the sync"]
        if skipped:
            parts.append(f"{skipped} changed source{'s are' if skipped != 1 else ' is'} not hashed (`SKIP`)")
    keys = new["pgp_keys"]
    if keys:
        parts.append(f"`validpgpkeys` pins {keys} key{'s' if keys != 1 else ''} for the signed sources makepkg checks")
    return "; ".join(parts)


def notes_block(release):
    text = (release.get("body") or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    if not text:
        return ""
    lines = text.split("\n")
    cut = len(lines) > NOTES_LINES or len(text) > NOTES_CHARS
    text = "\n".join(lines[:NOTES_LINES])
    if len(text) > NOTES_CHARS:
        head = text[:NOTES_CHARS]
        text = head.rsplit("\n", 1)[0] if "\n" in head else head
    # An indented code block: every line starts with four spaces, so no line
    # of the notes can end it, open a fence, or start HTML.
    block = "\n".join("    " + line if line.strip() else "" for line in text.split("\n"))
    more = f"\n\n{link('Full release notes', release['html_url'])}" if cut else ""
    return (f"<details>\n<summary>Release notes for {html.escape(cell(release.get('tag_name', '')))}</summary>\n\n"
            f"{block}{more}\n\n</details>")


def package_section(root, base, package, fetch_json):
    new = read_package(Path(root) / "pkgbuilds" / package)
    with tempfile.TemporaryDirectory(prefix="sync-pr-body-") as scratch:
        old = base_package(root, base, package, scratch)
    meta = new["meta"]
    before = version(old["first"]) if old else "none"
    after = version(new["first"])
    rows = source_rows(old, new)
    github = package_github(old, new)
    old_pkgver = watch.scalar(old["first"], "pkgver") if old else ""
    new_pkgver = watch.scalar(new["first"], "pkgver")
    same_version = bool(old) and old_pkgver == new_pkgver
    if same_version and not (github and github["old"]):
        github = None
    elif not same_version and declared_repo(meta) and not (github and github["kind"] == "tag" and github["old"]):
        tags = declared_tags(meta, [v for v in (new_pkgver, old_pkgver) if v], fetch_json)
        if new_pkgver in tags:
            github = {"repo": declared_repo(meta), "kind": "tag", "new": tags[new_pkgver], "old": tags.get(old_pkgver)}
    release = fetch_release(github, fetch_json)
    rebuilt = rebuilt_rows(old["meta"] if old else {}, meta)
    if same_version:
        lead = f"Rebuilds **{package}** from `{before}` to `{after}`" + (" against updated dependencies." if rebuilt else ".")
    else:
        lead = f"Updates **{package}** from `{before}` to `{after}`{change_label(old_pkgver, new_pkgver)}."

    table = [("Source", source_label(meta, new["hook"]))]
    if release:
        published = (release.get("published_at") or "")[:10]
        table.append(("Release", link(release.get("tag_name") or github["new"], release["html_url"]) + (f", published {published}" if published else "")))
    elif github and github["kind"] == "tag":
        table.append(("Tag", f"[{code(github['new'])}]({destination('https://github.com/' + github['repo'] + '/tree/' + quote(github['new'], safe='/'))})"))
    if github and github["old"]:
        shown = f"{short(github['old'])}...{short(github['new'])}"
        compare = f"https://github.com/{github['repo']}/compare/{quote(github['old'], safe='/')}...{quote(github['new'], safe='/')}"
        table.append(("Changes", f"[{code(shown)}]({destination(compare)})"))
    # Only lines the sync rewrote. A variable built from others (a download
    # URL from ${pkgver}) changes value too, but its line does not.
    pinned = [f"{code(name)} {code(short(old['assignments'][name]))} → {code(short(value))}"
              for name, value in sorted(new["assignments"].items())
              if old and name in old["assignments"] and old["assignments"][name] != value]
    if pinned:
        table.append(("Pinned", "<br>".join(pinned)))
    if rebuilt:
        table.append(("Rebuilt against", "<br>".join(rebuilt)))
    arches = new["arches"]
    table.append(("Arches", "any (x86_64 and aarch64)" if arches == ["any"] else ", ".join(arches)))
    table.append(("Ships to", ships_to(meta)))
    if meta.get("min_release_age"):
        table.append(("Minimum release age", cell(meta["min_release_age"])))
    table.append(("Verification", verification(rows, release, new)))

    summary = "| | |\n|---|---|\n" + "\n".join(f"| {name} | {value} |" for name, value in table)
    sources = ("**Sources**\n\n| Arch | File | Checksum |\n|---|---|---|\n"
               + "\n".join(f"| {label} | {source_cell(url, name)} | {checksum_text(checksums)} |" for label, url, name, checksums in rows)) if rows else ""
    record = {"name": package, "before": before, "after": after, "source": source_kind(meta, new["hook"]),
              "github": github, "arches": arches, "ships_to": ships_to(meta)}
    return {"name": package, "before": before, "after": after, "lead": lead, "summary": summary,
            "sources": sources, "notes": notes_block(release) if release else "", "record": record}


def assemble_body(sections, review=False):
    def record_comment(entries):
        data = json.dumps({"packages": entries, "review": bool(review)}, separators=(",", ":"), sort_keys=True)
        return f"<!-- omarchy-sync-pr {data.replace('--', chr(92) + 'u002d' + chr(92) + 'u002d')} -->"

    policy = REVIEW if review else AUTO_MERGE
    tail = [policy, record_comment([s["record"] for s in sections])]

    def assemble(parts_of, tail):
        out = []
        if len(sections) == 1:
            out += parts_of(sections[0])
        else:
            out.append(f"Updates {len(sections)} packages together.")
            out.append("| Package | From | To |\n|---|---|---|\n"
                       + "\n".join(f"| {cell(s['name'])} | {code(s['before'])} | {code(s['after'])} |" for s in sections))
            for section in sections:
                out += [f"### {cell(section['name'])}"] + parts_of(section)
        return "\n\n".join([part for part in out if part] + tail) + "\n"

    # Give up the longest parts first, so the body fits and its record stays whole.
    for parts_of in (lambda s: [s["lead"], s["summary"], s["sources"], s["notes"]],
                     lambda s: [s["lead"], s["summary"], s["sources"]],
                     lambda s: [s["lead"], s["summary"]],
                     lambda s: [s["lead"]]):
        body = assemble(parts_of, tail)
        if utf16(body) <= BODY_LIMIT:
            return body
    # Still too long: the record keeps only names, which tools can look up.
    names = record_comment([{"name": s["name"]} for s in sections])
    return "\n\n".join([f"Updates {len(sections)} packages together.", policy, names]) + "\n"


def build_body(root, packages, base="HEAD", review=False, fetch_json=None):
    return assemble_body([package_section(root, base, package, fetch_json) for package in packages], review)


def fetch_github_json(token):
    """GET a GitHub API URL with a short timeout; the token goes only to the API."""
    def fetch(url):
        if urlsplit(url).hostname != "api.github.com":
            raise ValueError(f"not a GitHub API URL: {url}")
        # --disable first: no ~/.curlrc can add headers, proxies or redirects.
        command = ["curl", "--disable", "--http1.1", "--proto", "=https", "-fsSL", "--connect-timeout", "10", "--max-time", "20",
                   "-H", "Accept: application/vnd.github+json"]
        config = f'header = "Authorization: Bearer {token}"\n' if token else ""
        if config:
            command += ["--config", "-"]
        result = subprocess.run(command + [url], input=config, capture_output=True, text=True, check=True, timeout=30)
        return json.loads(result.stdout)
    return fetch


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("packages", nargs="+", help="package directories in this PR's group")
    parser.add_argument("--base", default="HEAD", help="revision the change is compared with")
    parser.add_argument("--review", action="store_true", help="the group opens as a draft for review")
    parser.add_argument("--offline", action="store_true", help="do not look up GitHub releases")
    args = parser.parse_args(argv)
    token = None
    for name in TOKENS:
        token = os.environ.pop(name, None) or token
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    fetch_json = None if args.offline else fetch_github_json(token)
    sys.stdout.write(build_body(root, args.packages, args.base, args.review, fetch_json))


if __name__ == "__main__":
    main()
