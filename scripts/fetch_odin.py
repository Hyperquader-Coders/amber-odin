#!/usr/bin/env python3
"""Fetch an official compiled Odin release from GitHub and unpack it for
packaging. Verifies the asset against the sha256 digest the GitHub API
reports. Writes <dest>/make_args with VERSION= and SOURCE_DIR= for make."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

API = "https://api.github.com/repos/odin-lang/Odin/releases"


def api_get(url):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "amber-odin-fetch",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.load(res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", help="upstream tag (e.g. dev-2026-08); default latest")
    ap.add_argument("--arch", default="amd64", choices=["amd64", "arm64"])
    ap.add_argument("--dest", default="build/upstream")
    args = ap.parse_args()

    rel = api_get(f"{API}/tags/{args.tag}" if args.tag else f"{API}/latest")
    tag = rel["tag_name"]
    m = re.fullmatch(r"dev-(20\d\d)-(\d\d)", tag)
    if not m:
        sys.exit(f"unexpected upstream tag format: {tag}")
    version = f"{m.group(1)}.{m.group(2)}+dev"

    want = f"odin-linux-{args.arch}-{tag}.tar.gz"
    asset = next((a for a in rel["assets"] if a["name"] == want), None)
    if not asset:
        sys.exit(f"no asset {want} in release {tag}; assets: "
                 + ", ".join(a["name"] for a in rel["assets"]))
    digest = asset.get("digest", "")
    if not digest.startswith("sha256:"):
        sys.exit(f"API reports no sha256 digest for {want}; refusing to fetch")

    dest = Path(args.dest)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    tarball = dest / want
    print(f"fetching {want} ({asset['size'] // 1048576} MB)...")
    subprocess.run(["curl", "-sL", "-o", str(tarball),
                    asset["browser_download_url"]], check=True)

    h = hashlib.sha256()
    with open(tarball, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if f"sha256:{h.hexdigest()}" != digest:
        sys.exit(f"sha256 mismatch for {want}: got {h.hexdigest()}, "
                 f"API says {digest}")
    print(f"sha256 verified: {h.hexdigest()}")

    with tarfile.open(tarball) as t:
        t.extractall(dest, filter="data")

    # locate the directory holding the odin executable (layout varies)
    source_dir = None
    for cand in sorted(dest.rglob("odin")):
        if cand.is_file() and cand.stat().st_mode & 0o111:
            source_dir = cand.parent
            break
    if not source_dir:
        sys.exit("no executable 'odin' found in the unpacked release")
    tarball.unlink()

    # one assignment per line: the file is both `cat`-able into a make
    # command line and -include-able by the Makefile as defaults
    (dest / "make_args").write_text(
        f"VERSION={version}\nSOURCE_DIR={source_dir}\n")
    print(f"ready: tag={tag} VERSION={version} SOURCE_DIR={source_dir}")


if __name__ == "__main__":
    main()
