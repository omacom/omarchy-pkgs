#!/usr/bin/env python3
"""Discover releases and update our own recipes; never import upstream build code.

The watch selects release metadata. Sources, supported architectures, integrity
algorithms and packaging behavior stay in the checked-in PKGBUILD. Only release
scalars and checksum arrays are replaced, atomically, after every source passes.
"""
import argparse
import datetime as dt
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import quote, urlsplit
import zipfile

PROVIDERS = {"github", "git_tags", "git_branch", "npm", "pypi", "debian", "json", "regex", "archive", "redirect"}
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+]*\Z")
SCALAR = re.compile(r"[A-Za-z0-9._+/-]+\Z")
SUM = re.compile(r"(md5|sha1|sha224|sha256|sha384|sha512|b2)sums(_[a-z0-9_]+)?\Z")
HASHES = {"b2": "blake2b"}


def run(args, **kwargs):
    return subprocess.check_output(args, **kwargs)


def vercmp(a, b):
    return int(run(["vercmp", a, b], text=True).strip())


def https(url):
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or re.search(r"[\s\x00-\x1f]", url):
        raise ValueError(f"expected an HTTPS upstream URL: {url!r}")
    return url


class Fetcher:
    def __init__(self, cache):
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)

    def file(self, url):
        https(url)
        dest = self.cache / hashlib.sha256(url.encode()).hexdigest()
        if not dest.exists():
            scratch = dest.with_suffix(f".{os.getpid()}.tmp")
            command = ["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
                       "--connect-timeout", "20", "--max-time", "300", "--retry", "2", "-o", str(scratch), url]
            # Credentials only go to GitHub's API, never to release assets or vendors.
            token = os.environ.get("UPSTREAM_GITHUB_TOKEN")
            if token and urlsplit(url).hostname == "api.github.com":
                command[1:1] = ["--config", "-"]
                subprocess.run(command, input=f'header = "Authorization: Bearer {token}"\n', text=True, check=True)
            else:
                subprocess.run(command, check=True)
            scratch.replace(dest)
        return dest

    def text(self, url):
        data = self.file(url).read_bytes()
        if data.startswith(b"\x1f\x8b"):
            data = gzip.decompress(data)
        return data.decode()

    def json(self, url):
        return json.loads(self.text(url))


def validate(watch):
    if not isinstance(watch, dict) or len(PROVIDERS & watch.keys()) != 1:
        raise ValueError("watch must select exactly one release provider")
    provider = next(iter(PROVIDERS & watch.keys()))
    allowed = PROVIDERS | {"pattern", "path", "package", "branch", "variables", "fields",
                           "submodules", "allow_prerelease", "unescape_json", "filenames",
                           "sequence", "version", "revision", "revision_variable",
                           "mutable_sources", "member", "dist_tag"}
    if watch.keys() - allowed:
        raise ValueError(f"unknown watch fields: {sorted(watch.keys() - allowed)}")
    value = watch[provider]
    if not isinstance(value, str) or not value:
        raise ValueError(f"invalid watch.{provider}")
    if provider == "github":
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", value):
            raise ValueError("invalid GitHub repository")
    elif provider in {"npm", "pypi"}:
        if not re.fullmatch(r"(?:@[\w.-]+/)?[\w.-]+", value):
            raise ValueError("invalid registry package")
    else:
        https(value)
    if "pattern" in watch or provider in {"github", "git_tags", "regex", "archive", "redirect"}:
        if not isinstance(watch.get("pattern"), str):
            raise ValueError("watch needs an explicit release pattern")
        pattern = re.compile(watch["pattern"])
        if "version" not in pattern.groupindex:
            raise ValueError("release pattern needs a named version group")
    if provider == "json" and (not isinstance(watch.get("path"), str) or not watch["path"]):
        raise ValueError("JSON watch needs a version path")
    if provider == "debian":
        name = watch.get("package", "")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", name):
            raise ValueError("Debian watch needs an exact package name")
    if provider == "git_branch":
        branch = watch.get("branch", "")
        if not isinstance(branch, str) or not branch or branch.startswith("-"):
            raise ValueError("git branch watch needs an explicit branch")
        run(["git", "check-ref-format", "refs/heads/" + branch])
    for field in ("variables", "submodules", "fields"):
        mapping = watch.get(field, {})
        if not isinstance(mapping, dict):
            raise ValueError(f"watch.{field} must be a string mapping")
        for name, value in mapping.items():
            pattern = r"[a-z][a-z0-9_]*" if field == "fields" else r"_[a-z][a-z0-9_]*"
            if not re.fullmatch(pattern, name) or not isinstance(value, str) or not value:
                raise ValueError(f"invalid watch.{field} mapping")
    if "submodules" in watch and provider != "github":
        raise ValueError("submodules require a GitHub watch")
    if watch.get("variables", {}).keys() & watch.get("submodules", {}).keys():
        raise ValueError("a release variable cannot also be a submodule")
    for path in watch.get("submodules", {}).values():
        if path.startswith("/") or any(part in {"", ".", ".."} for part in path.split("/")):
            raise ValueError("submodule path must be relative to the release repository")
    for field in ("allow_prerelease", "unescape_json", "filenames", "sequence"):
        if field in watch and not isinstance(watch[field], bool):
            raise ValueError(f"watch.{field} must be boolean")
    for field in ("version", "revision", "member", "dist_tag"):
        if field in watch and (not isinstance(watch[field], str) or not watch[field]):
            raise ValueError(f"watch.{field} must be a string template")
    if "revision_variable" in watch:
        name = watch["revision_variable"]
        if not isinstance(name, str) or name not in watch.get("variables", {}) or not watch.get("revision"):
            raise ValueError("revision_variable requires a declared variable and revision template")
    for field in ("mutable_sources",):
        entries = watch.get(field, [])
        if not isinstance(entries, list) or any(not isinstance(v, str) or not re.fullmatch(r"source(?:_[a-z0-9_]+)?:[0-9]+", v) for v in entries):
            raise ValueError(f"watch.{field} must name source-array:index entries")
    return provider


def json_path(data, path):
    for key in path.split("."):
        data = data[int(key)] if isinstance(data, list) else data[key]
    return data


def candidate(watch, values):
    values = {k: str(v) for k, v in values.items() if v is not None}
    version = watch.get("version", "{version}").format_map(values)
    if not VERSION.fullmatch(version):
        raise ValueError(f"unusable upstream version: {version!r}")
    revision = watch.get("revision", "").format_map(values)
    if revision and not re.fullmatch(r"[0-9]+", revision):
        raise ValueError("upstream release revision must be numeric")
    return {"pkgver": version, "values": values,
            "published_at": values.get("published_at"),
            "revision": revision}


def matches(watch, text, extra=None, full=False):
    pattern = re.compile(watch["pattern"])
    found = [pattern.fullmatch(text)] if full else pattern.finditer(text)
    for match in found:
        if match:
            yield candidate(watch, {**(extra or {}), **match.groupdict()})


def discover(watch, fetch):
    provider = validate(watch)
    feed = watch[provider]
    results = []
    if provider == "github":
        releases = fetch.json(f"https://api.github.com/repos/{feed}/releases?per_page=100")
        if not isinstance(releases, list):
            raise ValueError("GitHub did not return a release list")
        for release in releases:
            if release.get("draft") or (release.get("prerelease") and not watch.get("allow_prerelease")):
                continue
            for item in matches(watch, release["tag_name"], {"tag": release["tag_name"], "published_at": release["published_at"]}, full=True):
                item["assets"] = release.get("assets", [])
                results.append(item)
    elif provider == "git_tags":
        refs = run(["git", "ls-remote", "--tags", feed], text=True)
        tags = {}
        for line in refs.splitlines():
            commit, ref = line.split()
            tag = ref.removeprefix("refs/tags/")
            if tag.endswith("^{}"):
                tags[tag[:-3]] = commit
            else:
                tags.setdefault(tag, commit)
        for tag, commit in tags.items():
            results.extend(matches(watch, tag, {"tag": tag, "commit": commit}, full=True))
    elif provider == "git_branch":
        with tempfile.TemporaryDirectory(prefix="upstream-git-") as work:
            subprocess.run(["git", "clone", "--quiet", "--bare", "--filter=blob:none", "--single-branch", "--branch", watch["branch"], feed, work], check=True)
            commit = run(["git", "-C", work, "rev-parse", "HEAD"], text=True).strip()
            count = run(["git", "-C", work, "rev-list", "--count", "HEAD"], text=True).strip()
            date = run(["git", "-C", work, "show", "-s", "--format=%cs", "HEAD"], text=True).strip().replace("-", "")
            timestamp = run(["git", "-C", work, "show", "-s", "--format=%cI", "HEAD"], text=True).strip()
            results.append(candidate(watch, {"version": date, "date": date, "count": count, "commit": commit, "published_at": timestamp}))
    elif provider == "npm":
        data = fetch.json("https://registry.npmjs.org/" + quote(feed, safe=""))
        version = data["dist-tags"][watch.get("dist_tag", "latest")]
        results.append(candidate(watch, {"version": version, "published_at": data.get("time", {}).get(version)}))
    elif provider == "pypi":
        data = fetch.json(f"https://pypi.org/pypi/{feed}/json")
        version = data["info"]["version"]
        dates = [r["upload_time_iso_8601"] for r in data["releases"].get(version, []) if not r.get("yanked")]
        if not dates:
            raise ValueError("PyPI release has no unyanked files")
        results.append(candidate(watch, {"version": version, "published_at": max(dates)}))
    elif provider == "debian":
        for stanza in re.split(r"\n\s*\n", fetch.text(feed).replace("\r", "")):
            fields = dict(re.findall(r"^([A-Za-z0-9-]+): (.*)$", stanza, re.M))
            if fields.get("Package") != watch["package"]:
                continue
            if "pattern" in watch:
                results.extend(matches(watch, fields["Version"], full=True))
            else:
                results.append(candidate(watch, {"version": fields["Version"]}))
    elif provider == "json":
        data = fetch.json(feed)
        values = {"version": json_path(data, watch["path"])}
        values.update({name: json_path(data, path) for name, path in watch.get("fields", {}).items()})
        results.append(candidate(watch, values))
    elif provider == "redirect":
        final_url = run(["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSLI", "--max-time", "60", "-o", "/dev/null", "-w", "%{url_effective}", feed], text=True)
        results.extend(matches(watch, final_url))
    elif provider == "regex":
        text = fetch.text(feed)
        if watch.get("unescape_json"):
            text = text.replace('\\"', '"')
        results.extend(matches(watch, text))
    elif provider == "archive":
        file = fetch.file(feed)
        if zipfile.is_zipfile(file):
            with zipfile.ZipFile(file) as archive:
                names = archive.namelist()
                if watch.get("filenames"):
                    results.extend(matches(watch, "\n".join(names)))
                for name in ([] if watch.get("filenames") else names):
                    if re.fullmatch(watch.get("member", ".*"), name):
                        results.extend(matches(watch, archive.read(name).decode()))
        elif file.read_bytes()[:8] == b"!<arch>\n":
            names = run(["bsdtar", "-tf", str(file)], text=True).splitlines()
            controls = [name for name in names if name.startswith("control.tar")]
            if len(controls) != 1:
                raise ValueError("deb does not contain exactly one control archive")
            data = run(["bsdtar", "-xOf", str(file), controls[0]])
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                members = [m for m in archive if m.name.removeprefix("./") == "control"]
                if len(members) != 1:
                    raise ValueError("deb control file is missing or ambiguous")
                results.extend(matches(watch, archive.extractfile(members[0]).read().decode()))
        else:
            with tarfile.open(file) as archive:
                for member in archive:
                    if member.isfile() and re.fullmatch(watch.get("member", ".*"), member.name):
                        results.extend(matches(watch, archive.extractfile(member).read().decode()))
    if not results:
        raise ValueError(f"no matching releases in {feed}")
    return results


def select_release(releases, min_age=0, now=None, bypass=False):
    now = now or dt.datetime.now(dt.timezone.utc)
    best = None
    for release in releases:
        if min_age and not bypass:
            value = release.get("published_at")
            if not value or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)", value):
                raise ValueError("release age cannot be established")
            if (now - dt.datetime.fromisoformat(value.replace("Z", "+00:00"))).total_seconds() < min_age:
                continue
        order = vercmp(release["pkgver"], best["pkgver"]) if best else 1
        if best and order == 0:
            order = vercmp(release["revision"] or "0", best["revision"] or "0")
        if order > 0:
            best = release
    return best


DUMP = r'''
source "$1" >/dev/null || exit 1
set +u
for __watch_name in pkgver pkgrel epoch arch $(compgen -A variable | LC_ALL=C sort); do
  case "$__watch_name" in
    pkgver|pkgrel|epoch|arch|source|source_*|md5sums*|sha1sums*|sha224sums*|sha256sums*|sha384sums*|sha512sums*|b2sums*|_*)
      [[ $__watch_name == __watch_* ]] && continue
      declare -n __watch_value="$__watch_name"
      printf '%s\0' "$__watch_name" "${#__watch_value[@]}" "${__watch_value[@]}"
      unset -n __watch_value
      ;;
  esac
done
'''


def read_recipe(path, arch="x86_64"):
    with tempfile.TemporaryDirectory(prefix="recipe-read-") as work:
        env = {**os.environ, "CARCH": arch, "SRCDEST": work, "srcdir": work, "pkgdir": work}
        data = run(["bash", "-c", DUMP, "_", str(path.resolve())], cwd=path.parent, env=env).decode().split("\0")
    result = {}
    index = 0
    while index < len(data) - 1:
        name, size = data[index:index + 2]
        index += 2
        size = int(size)
        result[name] = data[index:index + size]
        index += size
    return result


def scalar(recipe, name, default=""):
    return recipe.get(name, [default])[0] if recipe.get(name) else default


def replace_scalar(text, name, value):
    if not SCALAR.fullmatch(value):
        raise ValueError(f"unsafe {name} value")
    pattern = re.compile(r"^" + re.escape(name) + r"=.*$", re.M)
    if len(pattern.findall(text)) != 1:
        raise ValueError(f"expected one top-level {name}= assignment")
    return pattern.sub(lambda _: f"{name}={value}", text)


def replace_array(text, name, values):
    starts = list(re.finditer(r"^" + re.escape(name) + r"=\(", text, re.M))
    if len(starts) != 1:
        raise ValueError(f"expected one top-level {name}= array")
    start = starts[0]
    depth, quote_char, escaped, comment = 1, None, False, False
    for index in range(start.end(), len(text)):
        char = text[index]
        if comment:
            if char == "\n": comment = False
        elif escaped:
            escaped = False
        elif char == "\\" and quote_char != "'":
            escaped = True
        elif quote_char:
            if char == quote_char: quote_char = None
        elif char in "\"'": quote_char = char
        elif char == "#" and (index == 0 or text[index - 1].isspace()): comment = True
        elif char == "(": depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                replacement = name + "=(" + " ".join("'" + value + "'" for value in values) + ")"
                return text[:start.start()] + replacement + text[index + 1:]
    raise ValueError(f"unclosed {name} array")


def bump_pkgrel(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
        raise ValueError(f"invalid pkgrel: {value}")
    components = value.split(".")
    components[-1] = str(int(components[-1]) + 1)
    return ".".join(components)


def complete_version(recipe):
    return f"{scalar(recipe, 'epoch', '0')}:{scalar(recipe, 'pkgver')}-{scalar(recipe, 'pkgrel')}"


def hash_file(path, algorithm):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, HASHES.get(algorithm, algorithm)).hexdigest()


def source_url(source):
    return source.split("::", 1)[-1]


def git_source_file(url, cache):
    base, fragment = url.removeprefix("git+").split("#", 1)
    kind, ref = fragment.split("=", 1)
    https(base)
    if kind not in {"tag", "commit"} or (kind == "commit" and not re.fullmatch(r"[0-9a-f]{40}", ref)):
        raise ValueError("VCS sources must name an immutable commit or a checksummed tag")
    if kind == "tag":
        run(["git", "check-ref-format", "refs/tags/" + ref])
    dest = cache / (hashlib.sha256(url.encode()).hexdigest() + ".git.tar")
    if not dest.exists():
        with tempfile.TemporaryDirectory(prefix="upstream-source-", dir=cache) as work:
            subprocess.run(["git", "init", "--quiet", "--bare", work], check=True)
            subprocess.run(["git", "-C", work, "fetch", "--quiet", "--depth=1", base, "refs/tags/" + ref if kind == "tag" else ref], check=True)
            scratch = Path(work) / "source.tar"
            with scratch.open("wb") as output:
                subprocess.run(["git", "-c", "core.abbrev=no", "-C", work, "archive", "--format", "tar", "FETCH_HEAD"], stdout=output, check=True)
            # The cache must never retain partial archives after a git failure.
            scratch.replace(dest)
    return dest


def updated_checksums(before, after, package, fetch, release, watch):
    arrays = {}
    source_names = {key for key in before if key == "source" or key.startswith("source_")}
    if source_names != {key for key in after if key == "source" or key.startswith("source_")}:
        raise ValueError("release changed the set of source architectures")
    for source_name in sorted(source_names):
        old_sources, sources = before[source_name], after[source_name]
        suffix = source_name.removeprefix("source")
        names = [name for name in before if SUM.fullmatch(name) and (SUM.fullmatch(name)[2] or "") == suffix]
        if not sources:
            continue
        if len(sources) != len(old_sources) or not names:
            raise ValueError(f"{source_name}: sources changed shape or have no checksums")
        for name in names:
            if len(before[name]) != len(sources):
                raise ValueError(f"{name}: source/checksum count mismatch")
            values = []
            algorithm = SUM.fullmatch(name)[1]
            for index, source in enumerate(sources):
                old = before[name][index]
                if source == old_sources[index] and f"{source_name}:{index}" not in watch.get("mutable_sources", []):
                    values.append(old)
                    continue
                url = source_url(source)
                # A release API digest can supply SHA256 without downloading a
                # large asset, but only when its exact declared URL matches.
                assets = [a for a in release.get("assets", []) if a.get("browser_download_url") == url]
                if algorithm == "sha256" and len(assets) == 1 and re.fullmatch(r"sha256:[0-9a-f]{64}", assets[0].get("digest") or ""):
                    values.append("SKIP" if old == "SKIP" else assets[0]["digest"][7:])
                    continue
                if url.startswith("git+https://"):
                    file = git_source_file(url, fetch.cache)
                elif url.startswith("https://"):
                    file = fetch.file(url)
                elif "://" not in url:
                    file = (package / url).resolve()
                    if not file.is_relative_to(package.resolve()) or not file.is_file():
                        raise ValueError(f"unsafe local source: {url}")
                else:
                    raise ValueError(f"unsupported source transport: {url}")
                # Preserve existing signature/prepare()-verified sources. Never
                # introduce SKIP; still fetch changed URLs to verify availability.
                values.append("SKIP" if old == "SKIP" else hash_file(file, algorithm))
            if values != before[name]:
                arrays[name] = values
    return arrays


def resolve_release_fields(watch, release, fetch):
    values = release["values"].copy()
    if "github" in watch and any("{commit}" in value for value in watch.get("variables", {}).values()):
        ref = fetch.json(f"https://api.github.com/repos/{watch['github']}/git/ref/tags/{quote(values['tag'], safe='')}")['object']
        if ref['type'] == 'tag':
            ref = fetch.json(f"https://api.github.com/repos/{watch['github']}/git/tags/{ref['sha']}")['object']
        if ref['type'] != 'commit' or not re.fullmatch(r"[0-9a-f]{40}", ref['sha']):
            raise ValueError("release tag does not resolve to a commit")
        values['commit'] = ref['sha']
    variables = {k: template.format_map(values) for k, template in watch.get('variables', {}).items()}
    for name, path in watch.get('submodules', {}).items():
        entry = fetch.json(f"https://api.github.com/repos/{watch['github']}/contents/{quote(path, safe='/')}?ref={quote(values['tag'], safe='')}")
        if not entry.get('submodule_git_url') or not re.fullmatch(r"[0-9a-f]{40}", entry.get('sha', '')):
            raise ValueError(f"release does not contain submodule {path}")
        variables[name] = entry['sha']
    if any(not SCALAR.fullmatch(value) for value in variables.values()):
        raise ValueError("unsafe release variable value")
    release['variables'] = variables
    return release


def sync(package, fetch, min_age=0, check=False):
    metadata = json.loads((package / ".omarchy/package.json").read_text())
    if metadata.get("sync") is False:
        return {"status": "skipped", "reason": "upstream updates held by sync=false"}
    watch = metadata["upstream"]["watch"]
    validate(watch)
    path = package / "PKGBUILD"
    original = path.read_text()
    before = read_recipe(path)
    release = select_release(discover(watch, fetch), min_age, bypass=os.environ.get("BYPASS_MIN_RELEASE_AGE") == "1")
    if release is None:
        return {"status": "skipped", "reason": "minimum release age"}
    current = scalar(before, "pkgver")
    if watch.get('sequence'):
        prefix, counter, identity = current.rsplit('.', 2)
        new_prefix, new_identity = release['values']['version'], release['values']['hash']
        if new_prefix == prefix:
            release['pkgver'] = current if new_identity == identity else f"{prefix}.{int(counter) + 1}.{new_identity}"
    order = vercmp(release["pkgver"], current)
    if order < 0:
        return {"status": "skipped", "current": current, "available": release["pkgver"], "reason": "upstream is older"}
    if order == 0 and not watch.get("revision_variable"):
        return {"status": "skipped", "current": current, "reason": "already current"}
    release = resolve_release_fields(watch, release, fetch)
    changed_variables = {k: v for k, v in release["variables"].items() if scalar(before, k) != v}
    if order == 0 and not changed_variables:
        return {"status": "skipped", "current": current, "reason": "already current"}
    if order == 0 and changed_variables:
        # Only a declared, forward-moving release revision can rebuild the same
        # version. A changed hash/commit alone is an immutable-release violation.
        revision_field = watch.get("revision_variable")
        if revision_field not in changed_variables or vercmp(changed_variables[revision_field], scalar(before, revision_field, "0")) <= 0:
            raise ValueError("release metadata changed without a newer version/revision")
    new_pkgrel = "1" if order > 0 else bump_pkgrel(scalar(before, "pkgrel"))
    text = replace_scalar(original, "pkgver", release["pkgver"])
    text = replace_scalar(text, "pkgrel", new_pkgrel)
    for name, value in release["variables"].items():
        text = replace_scalar(text, name, value)
    if check:
        return {"status": "available", "current": current, "release": release}
    scratch = path.with_name("PKGBUILD.sync-upstream")
    try:
        scratch.write_text(text)
        after = read_recipe(scratch)
        if scalar(after, "pkgver") != release["pkgver"] or scalar(after, "pkgrel") != new_pkgrel:
            raise ValueError("recipe did not retain the release version")
        if vercmp(complete_version(after), complete_version(before)) <= 0:
            raise ValueError("complete package version must increase")
        if before["arch"] != after["arch"]:
            raise ValueError("release changed supported architectures")
        arrays = updated_checksums(before, after, package, fetch, release, watch)
        for name, values in arrays.items():
            text = replace_array(text, name, values)
        scratch.write_text(text)
        subprocess.run(["bash", "-n", str(scratch)], check=True)
        for arch in before["arch"]:
            result = read_recipe(scratch, "x86_64" if arch == "any" else arch)
            if complete_version(result) != complete_version(after):
                raise ValueError(f"{arch}: inconsistent release version")
            for name, values in arrays.items():
                if result.get(name) != values:
                    raise ValueError(f"{arch}: rewritten {name} differs from the checked source hashes")
            for name in after:
                if name == "source" or name.startswith("source_"):
                    if result.get(name) != after[name]:
                        raise ValueError(f"{arch}: conditional {name} differs from the checked sources; use source_<arch> arrays")
        scratch.chmod(path.stat().st_mode)
        scratch.replace(path)
        return {"status": "updated", "before": complete_version(before), "after": complete_version(after)}
    finally:
        scratch.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["sync", "check", "validate"])
    parser.add_argument("package", type=Path)
    parser.add_argument("--min-age", type=int, default=0)
    args = parser.parse_args()
    package = args.package.resolve()
    if args.command == "validate":
        validate(json.loads((package / ".omarchy/package.json").read_text())["upstream"]["watch"])
        return
    with tempfile.TemporaryDirectory(prefix="upstream-watch-") as cache:
        fetch = Fetcher(os.environ.get("UPSTREAM_CACHE_DIR", cache))
        print(json.dumps(sync(package, fetch, args.min_age, check=args.command == "check")))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, re.error, OSError, subprocess.CalledProcessError) as error:
        print(f"upstream watch failed: {error}", file=sys.stderr)
        sys.exit(1)
