#!/usr/bin/env python3
"""Fetch ols (Odin Language Server) source at the current master commit.
GitHub generates archive tarballs on the fly, so there is no stable digest
to verify; the commit sha IS the pin -- it is recorded in <dest>/COMMIT and
belongs in the release notes. ols is built from source with the packaged
compiler so the pair can never skew."""
import argparse
import json
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

API = "https://api.github.com/repos/DanielGavin/ols"


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
    ap.add_argument("--commit", help="ols commit sha; default master head")
    ap.add_argument("--dest", default="build/ols-src")
    args = ap.parse_args()

    sha = args.commit or api_get(f"{API}/commits/master")["sha"]
    dest = Path(args.dest)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    url = f"https://github.com/DanielGavin/ols/archive/{sha}.tar.gz"
    print(f"fetching ols @ {sha[:12]}...")
    subprocess.run(
        ["sh", "-c",
         f"curl -sL '{url}' | tar xz -C '{dest}' --strip-components=1"],
        check=True)
    if not (dest / "src").is_dir() or not (dest / "LICENSE").exists():
        sys.exit("unpacked ols source looks wrong (no src/ or LICENSE)")
    (dest / "COMMIT").write_text(sha + "\n")
    print(f"ready: {dest} @ {sha}")


if __name__ == "__main__":
    main()
