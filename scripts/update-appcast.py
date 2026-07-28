#!/usr/bin/env python3
"""Insert a new release item into appcast.xml.

appcast.xml is the release: Sparkle reads nothing else, so a mistake here is
invisible in code review and only shows up as "you're up to date" on a user's
machine, or as a silently rejected update. Hence the checks below.

Edits are made textually rather than via ElementTree, which would rewrite the
whole document's formatting and namespace prefixes for a one-item change.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = "llatser-dot/beers"
APPCAST = Path(__file__).resolve().parent.parent / "appcast.xml"

ITEM = """        <item>
            <title>{short_version}</title>
            <pubDate>{pub_date}</pubDate>
            <link>https://github.com/{repo}/releases/tag/{tag}</link>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{minimum_system}</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure
                url="https://github.com/{repo}/releases/download/{tag}/Beers-{short_version}.app.zip"
                sparkle:edSignature="{signature}"
                length="{length}"
                type="application/octet-stream" />
        </item>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="build number, e.g. 132")
    parser.add_argument("--short-version", required=True, help="e.g. 1.3.2")
    parser.add_argument("--tag", required=True, help="e.g. v1.3.2")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature")
    parser.add_argument("--length", required=True, help="byte count of the zip")
    parser.add_argument("--pub-date", required=True, help="RFC 822 date")
    parser.add_argument("--minimum-system", default="14.0")
    parser.add_argument("--appcast", type=Path, default=APPCAST)
    args = parser.parse_args()

    text = args.appcast.read_text(encoding="utf-8")

    if not args.version.isdigit():
        print(f"--version must be a plain build number, got {args.version!r}", file=sys.stderr)
        return 1

    # Sparkle compares build numbers numerically. A duplicate means existing
    # installs never see the update; a lower one means the same, silently.
    existing = [int(v) for v in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", text)]
    new_version = int(args.version)
    if new_version in existing:
        print(f"Build {new_version} is already in the appcast", file=sys.stderr)
        return 1
    if existing and new_version < max(existing):
        print(
            f"Build {new_version} is lower than the published {max(existing)}; "
            "Sparkle would never offer it",
            file=sys.stderr,
        )
        return 1

    if int(args.length) <= 0:
        print("--length must be the real byte count of the uploaded zip", file=sys.stderr)
        return 1

    item = ITEM.format(
        repo=REPO,
        tag=args.tag,
        version=args.version,
        short_version=args.short_version,
        pub_date=args.pub_date,
        signature=args.signature,
        length=args.length,
        minimum_system=args.minimum_system,
    )

    # Newest item first: Sparkle picks the highest version regardless, but the
    # feed is also read by humans.
    marker = "        <item>"
    if marker in text:
        updated = text.replace(marker, item + marker, 1)
    else:
        updated = text.replace("    </channel>", item + "    </channel>", 1)

    if updated == text:
        print("Could not find an insertion point in the appcast", file=sys.stderr)
        return 1

    args.appcast.write_text(updated, encoding="utf-8")
    print(f"Added {args.short_version} (build {args.version}) to {args.appcast.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
