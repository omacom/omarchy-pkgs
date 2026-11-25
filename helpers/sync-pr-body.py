#!/usr/bin/env python3
"""Write the description of a sync PR from the change it carries.

package-prs.yml runs this after it applies one group's recipes to the working
tree. For each package it compares the recipe and .omarchy/package.json at
--base with the working tree, and prints Markdown: what moved, where it came
from, what was checked, and where it ships. Every source type gets the same
facts, because they come from the change itself. Where a source is a tag on
GitHub, the release's link, date, notes and asset digests come from GitHub's
API, unless --offline is given or the lookup fails.

Release notes are upstream's text: they go inside a code fence longer than any
backtick run in them, so they render as inert text, mention nobody and run no
HTML. A hidden comment at the end repeats the facts as JSON for tools.
"""
import argparse
import importlib.util
import json
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
BODY_LIMIT = 60000
COMMIT = re.compile(r"[0-9a-f]{40}")
ARCHIVE = r"\.(?:tar\.gz|tar\.bz2|tar\.xz|tar\.zst|tgz|zip)"
AUTO_MERGE = ("Auto-merges once `result`, `self-tests` and `build-isolation` pass. "
              "A failing build leaves it open for a maintainer without holding back any other package.")
REVIEW = ("Opened as a draft: a package in it is marked `review`. "
          "A maintainer reads it and marks it ready, and it lands once green.")


def cell(text):
    """Keep a value inside its table cell."""
    return str(text).replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def code(text):
    text = cell(text)
    fence = "``" if "`" in text else "`"
    return f"{fence}{text}{fence}"


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


def link(text, url):
    return f"[{cell(text)}]({url})"


def github_ref(source):
    """(owner/repo, "tag" or "commit", ref) for a source on GitHub, else None."""
    url = source.split("::", 1)[1] if "::" in source else source
    url = url.removeprefix("git+")
    parts = urlsplit(url)
    host, path = parts.hostname or "", parts.path
    found = None
    if host == "github.com":
        repo = re.fullmatch(r"/([^/]+)/([^/]+?)(?:\.git)?/?", path)
        if repo and parts.fragment:
            kind, _, ref = parts.fragment.partition("=")
            return (f"{repo[1]}/{repo[2]}", kind, unquote(ref)) if kind in ("tag", "commit") and ref else None
        found = (re.fullmatch(r"/([^/]+)/([^/]+)/releases/download/([^/]+)/[^/]+", path)
                 or re.fullmatch(rf"/([^/]+)/([^/]+)/archive/refs/tags/(.+?){ARCHIVE}", path)
                 or re.fullmatch(rf"/([^/]+)/([^/]+)/archive/(.+?){ARCHIVE}", path))
    elif host == "codeload.github.com":
        found = re.fullmatch(r"/([^/]+)/([^/]+)/(?:tar\.gz|zip|legacy\.tar\.gz)/(?:refs/tags/)?(.+)", path)
    elif host == "raw.githubusercontent.com":
        found = re.fullmatch(r"/([^/]+)/([^/]+)/(?:refs/tags/)?([^/]+)/.+", path)
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


def source_label(meta, has_hook):
    upstream = meta.get("upstream")
    if isinstance(upstream, dict) and isinstance(upstream.get("watch"), dict):
        spec, declarative = upstream["watch"], False
    elif isinstance(upstream, dict):
        spec, declarative = upstream, True
    else:
        spec, declarative = {}, False
    kind = next((name for name in sorted(watch.PROVIDERS) if name in spec), None)
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
    upstream = meta.get("upstream")
    spec = upstream.get("watch") if isinstance(upstream, dict) and isinstance(upstream.get("watch"), dict) else upstream
    if isinstance(spec, dict):
        kind = next((name for name in sorted(watch.PROVIDERS) if name in spec), None)
        if kind:
            return {"kind": kind, "declarative": "watch" not in upstream}
    return {"kind": "hook" if has_hook else "rebuild" if meta.get("rebuild_on") else "none", "declarative": False}


def ships_to(meta):
    if meta.get("pinned") is True:
        return "edge; rc only through a release candidate"
    if meta.get("release_ring") == "fast":
        return "edge, rc and stable (fast ring)"
    return "edge; rc and stable by promotion"


def pgp_key_count(directory):
    """How many keys validpgpkeys pins; makepkg checks each .sig source against them."""
    script = 'source "$1" >/dev/null || exit 1; printf %s "${#validpgpkeys[@]}"'
    with tempfile.TemporaryDirectory(prefix="recipe-keys-") as work:
        env = {"PATH": "/usr/bin:/bin", "CARCH": "x86_64", "SRCDEST": work, "srcdir": work, "pkgdir": work}
        return int(watch.run(["bash", "-c", script, "_", str((directory / "PKGBUILD").resolve())],
                             cwd=directory, env=env, text=True) or 0)


def assignments(directory):
    """Literal `_name=value` lines: the scalars the sync rewrites in place."""
    path = directory / "PKGBUILD"
    if not path.is_file():
        return {}
    found = re.findall(r"^(_[A-Za-z0-9_]+)=([^\n]*)$", path.read_text(), re.M)
    return {name: value.strip().strip("\"'") for name, value in found}


def read_package(directory):
    """Recipe values per architecture, and the package metadata."""
    first = watch.read_recipe(directory / "PKGBUILD")
    arches = first.get("arch") or ["x86_64"]
    recipes = {arch: watch.read_recipe(directory / "PKGBUILD", "x86_64" if arch == "any" else arch) for arch in arches}
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


def arch_keys(arch, recipe):
    """The source arrays a build for this architecture uses."""
    return [key for key in ("source", f"source_{arch}") if key in recipe]


def source_rows(old, new):
    """Each source whose URL or checksum changed: (arch label, url, name, [(algorithm, before, after)])."""
    rows, seen = [], set()
    for arch, recipe in new["recipes"].items():
        before = (old["recipes"].get(arch) or old["first"]) if old else {}
        for key in arch_keys(arch, recipe):
            if key in seen:
                continue
            seen.add(key)
            suffix = key.removeprefix("source")
            label = "all" if key == "source" else arch
            sums = [name for name in recipe if watch.SUM.fullmatch(name) and (watch.SUM.fullmatch(name)[2] or "") == suffix]
            previous_sources = before.get(key, [])
            for index, source in enumerate(recipe[key]):
                old_source = previous_sources[index] if index < len(previous_sources) else None
                checksums = []
                for name in sums:
                    after = recipe[name][index] if index < len(recipe[name]) else ""
                    previous = before.get(name, [])
                    checksums.append((watch.SUM.fullmatch(name)[1], previous[index] if index < len(previous) else "", after))
                if source != old_source or any(b != a for _, b, a in checksums):
                    url = source.split("::", 1)[1] if "::" in source else source
                    rows.append((label, url, source_name(source), checksums))
    return rows


def checksum_text(checksums):
    parts = []
    for algorithm, before, after in checksums:
        if before and before != after:
            parts.append(f"{algorithm} {code(short(before))} → {code(short(after))}")
        else:
            parts.append(f"{algorithm} {code(short(after))}")
    return "<br>".join(parts) or "none"


def package_github(old, new):
    """The GitHub repository and the refs the sources moved between."""
    pairs = []
    for arch, recipe in new["recipes"].items():
        before = (old["recipes"].get(arch) or old["first"]) if old else {}
        for key in arch_keys(arch, recipe):
            previous = before.get(key, [])
            pairs += [(previous[i] if i < len(previous) else None, source) for i, source in enumerate(recipe[key])]
    candidates = []
    for previous, source in pairs:
        after = github_ref(source)
        if not after:
            continue
        before_ref = github_ref(previous) if previous else None
        moved = before_ref and before_ref[0] == after[0] and before_ref[2] != after[2]
        candidates.append((not moved, "/releases/download/" not in source, after, before_ref if moved else None))
    if not candidates:
        return None
    _, _, after, before_ref = sorted(candidates, key=lambda item: item[:2])[0]
    return {"repo": after[0], "kind": after[1], "new": after[2], "old": before_ref[2] if before_ref else None}


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


def rebuilt_rows(old_meta, new_meta):
    moved = {}
    before = old_meta.get("rebuilt_against") or {}
    for arch, deps in (new_meta.get("rebuilt_against") or {}).items():
        for dep, value in deps.items():
            previous = (before.get(arch) or {}).get(dep)
            if previous != value:
                moved.setdefault((dep, previous or "none", value), []).append(arch)
    order = {arch: index for index, arch in enumerate(ARCHES)}
    return [f"{code(dep)} {code(a)} → {code(b)} ({', '.join(sorted(arches, key=lambda x: order.get(x, 9)))})"
            for (dep, a, b), arches in sorted(moved.items())]


def verification(rows, release, new):
    changed = [(url, algorithm, after) for _, url, _, checksums in rows
               for algorithm, before, after in checksums if after != "SKIP" and before != after]
    if not rows:
        parts = ["same sources and checksums as before"]
    elif not changed:
        parts = ["no checksum changed"]
    else:
        digests = {}
        for asset in (release or {}).get("assets", []):
            digest = asset.get("digest") or ""
            if digest.startswith("sha256:"):
                digests[asset.get("browser_download_url")] = digest[7:]
        if digests and all(algorithm == "sha256" and digests.get(url) == after for url, algorithm, after in changed):
            parts = ["sha256 of every new source matches the digest GitHub lists for it"]
        else:
            parts = ["checksums recorded by the sync from the downloaded files"]
    keys = new["pgp_keys"]
    if keys:
        parts.append(f"PGP signature checked by makepkg against {keys} pinned key{'s' if keys != 1 else ''}")
    return "; ".join(parts)


def notes_block(release):
    text = (release.get("body") or "").replace("\r\n", "\n").strip()
    if not text:
        return ""
    lines = text.split("\n")
    cut = len(lines) > NOTES_LINES or len(text) > NOTES_CHARS
    text = "\n".join(lines[:NOTES_LINES])
    if len(text) > NOTES_CHARS:
        text = text[:NOTES_CHARS].rsplit("\n", 1)[0] if "\n" in text[:NOTES_CHARS] else text[:NOTES_CHARS]
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    more = f"\n\n{link('Full release notes', release['html_url'])}" if cut else ""
    return (f"<details>\n<summary>Release notes for {cell(release.get('tag_name', ''))}</summary>\n\n"
            f"{fence}text\n{text}\n{fence}{more}\n</details>")


def package_section(root, base, package, fetch_json):
    new = read_package(Path(root) / "pkgbuilds" / package)
    with tempfile.TemporaryDirectory(prefix="sync-pr-body-") as scratch:
        old = base_package(root, base, package, scratch)
    meta = new["meta"]
    before = version(old["first"]) if old else "none"
    after = version(new["first"])
    rows = source_rows(old, new)
    github = package_github(old, new)
    same_version = bool(old) and watch.scalar(old["first"], "pkgver") == watch.scalar(new["first"], "pkgver")
    if same_version and not (github and github["old"]):
        github = None
    release = fetch_release(github, fetch_json)
    rebuilt = rebuilt_rows(old["meta"] if old else {}, meta)
    if same_version:
        lead = f"Rebuilds **{package}** from `{before}` to `{after}`" + (" against updated dependencies." if rebuilt else ".")
    else:
        old_pkgver = watch.scalar(old["first"], "pkgver") if old else ""
        lead = f"Updates **{package}** from `{before}` to `{after}`{change_label(old_pkgver, watch.scalar(new['first'], 'pkgver'))}."

    table = [("Source", source_label(meta, new["hook"]))]
    if release:
        published = (release.get("published_at") or "")[:10]
        table.append(("Release", link(release.get("tag_name") or github["new"], release["html_url"]) + (f", published {published}" if published else "")))
    elif github and github["kind"] == "tag":
        table.append(("Tag", f"[{code(github['new'])}](https://github.com/{github['repo']}/tree/{quote(github['new'], safe='/')})"))
    if github and github["old"]:
        shown = f"{short(github['old'])}...{short(github['new'])}"
        table.append(("Changes", f"[{code(shown)}](https://github.com/{github['repo']}/compare/{quote(github['old'], safe='/')}...{quote(github['new'], safe='/')})"))
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

    parts = [lead, "| | |\n|---|---|\n" + "\n".join(f"| {name} | {value} |" for name, value in table)]
    if rows:
        parts.append("**Sources**\n\n| Arch | File | Checksum |\n|---|---|---|\n"
                     + "\n".join(f"| {label} | {code(name)} | {checksum_text(checksums)} |" for label, _, name, checksums in rows))
    notes = notes_block(release) if release else ""
    record = {"name": package, "before": before, "after": after, "source": source_kind(meta, new["hook"]),
              "github": github, "arches": arches, "ships_to": ships_to(meta)}
    return {"name": package, "before": before, "after": after, "parts": parts, "notes": notes, "record": record}


def build_body(root, packages, base="HEAD", review=False, fetch_json=None):
    sections = [package_section(root, base, package, fetch_json) for package in packages]

    def assemble(with_notes):
        out = []
        if len(sections) == 1:
            section = sections[0]
            out += section["parts"] + ([section["notes"]] if with_notes and section["notes"] else [])
        else:
            out.append(f"Updates {len(sections)} packages together.")
            out.append("| Package | From | To |\n|---|---|---|\n"
                       + "\n".join(f"| {s['name']} | `{s['before']}` | `{s['after']}` |" for s in sections))
            for section in sections:
                out.append(f"### {section['name']}")
                out += section["parts"] + ([section["notes"]] if with_notes and section["notes"] else [])
        out.append(REVIEW if review else AUTO_MERGE)
        record = json.dumps({"packages": [s["record"] for s in sections], "review": bool(review)},
                            separators=(",", ":"), sort_keys=True).replace("--", "\\u002d\\u002d")
        out.append(f"<!-- omarchy-sync-pr {record} -->")
        return "\n\n".join(out) + "\n"

    body = assemble(True)
    return body if len(body) <= BODY_LIMIT else assemble(False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("packages", nargs="+", help="package directories in this PR's group")
    parser.add_argument("--base", default="HEAD", help="revision the change is compared with")
    parser.add_argument("--review", action="store_true", help="the group opens as a draft for review")
    parser.add_argument("--offline", action="store_true", help="do not look up GitHub releases")
    args = parser.parse_args(argv)
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="sync-pr-body-cache-") as cache:
        fetch_json = None if args.offline else watch.Fetcher(cache).json
        sys.stdout.write(build_body(root, args.packages, args.base, args.review, fetch_json))


if __name__ == "__main__":
    main()
