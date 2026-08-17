#!/usr/bin/env python3
import argparse
import json
import re
import sys
import urllib.error
import urllib.request


LATEST_URL = "https://api.github.com/repos/odin-lang/Odin/releases/latest"


def version_key(text):
    """Extract a comparable year/month key from Odin and Debian-ish versions."""
    patterns = [
        r"(?P<year>20\d{2})[.\-_](?P<month>0?[1-9]|1[0-2])",
        r"dev-(?P<year>20\d{2})-(?P<month>0?[1-9]|1[0-2])",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return int(match.group("year")), int(match.group("month"))
    return None


def fetch_latest(url, timeout):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "amber-odin-release-check",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as res:
        return json.load(res)


def main():
    parser = argparse.ArgumentParser(
        description="Check the latest official Odin GitHub release."
    )
    parser.add_argument("--current", required=True, help="Current packaged Odin version")
    parser.add_argument("--url", default=LATEST_URL, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    args = parser.parse_args()

    try:
        latest = fetch_latest(args.url, args.timeout)
    except urllib.error.URLError as err:
        print(f"failed to fetch Odin release metadata: {err}", file=sys.stderr)
        return 2

    tag = latest.get("tag_name") or ""
    name = latest.get("name") or tag
    published_at = latest.get("published_at") or ""
    html_url = latest.get("html_url") or ""
    assets = [asset.get("name", "") for asset in latest.get("assets", [])]

    current_key = version_key(args.current)
    latest_key = version_key(tag) or version_key(name)
    newer = None
    if current_key is not None and latest_key is not None:
        newer = latest_key > current_key

    result = {
        "current": args.current,
        "latest_tag": tag,
        "latest_name": name,
        "published_at": published_at,
        "url": html_url,
        "newer": newer,
        "assets": assets,
    }

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    print(f"current: {args.current}")
    print(f"latest:  {name} ({tag})")
    if published_at:
        print(f"date:    {published_at}")
    if html_url:
        print(f"url:     {html_url}")

    linux_assets = [name for name in assets if "linux" in name.lower()]
    if linux_assets:
        print("linux assets:")
        for asset in linux_assets:
            print(f"  {asset}")

    if newer is True:
        print("status:  newer Odin release is available")
    elif newer is False:
        print("status:  current package is up to date")
    else:
        print("status:  could not compare versions automatically")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
