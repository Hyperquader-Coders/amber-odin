#!/usr/bin/env python3
import argparse
import hashlib
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def command_output(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def normalize_odin_version(output):
    marker = " version "
    if marker in output:
        return output.split(marker, 1)[1].strip()
    return output.strip()


def packaged_odin_version(deb_path, package):
    root = tempfile.mkdtemp(prefix=f"{package}-release-")
    try:
        subprocess.check_call(["dpkg-deb", "-x", deb_path, root])
        odin_bin = os.path.join(root, "usr", "bin", "odin")
        if not os.path.exists(odin_bin):
            raise SystemExit(f"packaged odin missing: {odin_bin}")
        version = command_output([odin_bin, "version"])
        if not version:
            raise SystemExit("packaged odin did not report a version")
        return normalize_odin_version(version)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Write amber-odin release manifest.")
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--deb", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if not os.path.exists(args.deb):
        raise SystemExit(f"missing deb: {args.deb}")

    odin_version = packaged_odin_version(args.deb, args.package)
    deb_size = os.path.getsize(args.deb)
    deb_sha256 = sha256_file(args.deb)
    released_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    content = f"""# {args.package} Release

Package: {args.package}
Version: {args.version}
Architecture: {args.arch}
Released-At: {released_at}
Packaged-Odin-Version: {odin_version}
Source-Dir: {args.source_dir}

Deb: {args.deb}
Deb-Size: {deb_size}
Deb-SHA256: {deb_sha256}

Workflow:
1. make release-check
2. update local Odin and package VERSION when needed
3. make release
4. ingest the deb into the apt archive: amberlinux-apt's make add-suite
"""

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"wrote {args.output}")
    print(f"sha256 {deb_sha256}  {args.deb}")


if __name__ == "__main__":
    raise SystemExit(main())
