#!/usr/bin/env python3
"""news-check.py: has Arch posted news since the last successful update?

Part of kitchen-update (S3, the compatibility preflight). Arch news is where
"manual intervention required" is announced, and Omarchy has no news handling
of its own, so an unattended update must not run past a new item.

usage: news-check.py FEED.xml --since ISO8601 [--since ISO8601 ...]
                     [--policy hold-all|keywords] [--installed FILE]

--since may repeat; the newest one wins. kitchen-update passes both its own
last-success stamp and the last "starting full system upgrade" in pacman.log,
so an attended `omarchy update` also clears a hold.

Policies:
  hold-all  (default) any item newer than --since holds the night.
  keywords  only items whose title says manual intervention, breaking or
            requires, or names an installed package, hold; others only notify.

Output, per new item, newest first:
  HOLD <date> <title>  [installed: pkg, ...]
       <link>
  NEWS <date> <title>
       <link>

exit 0: nothing new    10: new items, none hold-worthy (keywords policy only)
exit 11: hold          3: the feed or a date could not be read (hold: a human looks)
"""

import argparse
import datetime
import email.utils
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

URGENT = re.compile(r"manual intervention|breaking|requires", re.I)
WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._-]*[A-Za-z0-9+]")


def parse_since(value):
    """ISO 8601 with an offset. pacman.log writes -0400; fromisoformat on
    Python >= 3.11 takes that too, but normalise it for older ones."""
    value = value.strip()
    value = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", value)
    when = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if when.tzinfo is None:
        # A naive stamp is ambiguous; UTC errs on the side of showing more news.
        when = when.replace(tzinfo=datetime.timezone.utc)
    return when


def installed_packages(path):
    if path:
        with open(path) as f:
            return set(f.read().split())
    try:
        out = subprocess.run(["pacman", "-Qq"], capture_output=True, text=True, check=False).stdout
    except OSError:
        return set()
    return set(out.split())


def main():
    parser = argparse.ArgumentParser(description="Hold an unattended update on new Arch news.")
    parser.add_argument("feed")
    parser.add_argument("--since", action="append", required=True)
    parser.add_argument("--policy", choices=("hold-all", "keywords"), default="hold-all")
    parser.add_argument("--installed", help="file with installed package names (default: pacman -Qq)")
    args = parser.parse_args()

    try:
        since = max(parse_since(s) for s in args.since if s.strip())
    except ValueError as e:
        print(f"HOLD cannot read a --since date ({e})")
        return 3

    try:
        items = list(ET.parse(args.feed).getroot().iter("item"))
    except (ET.ParseError, OSError) as e:
        print(f"HOLD cannot read the Arch news feed ({e})")
        return 3

    installed = installed_packages(args.installed)
    rc = 0
    found = []
    for item in items:
        title = (item.findtext("title") or "").strip()
        link = (item.findtext("link") or "").strip()
        try:
            when = email.utils.parsedate_to_datetime(item.findtext("pubDate") or "")
        except (TypeError, ValueError):
            # An undated item is treated as new: failing safe means a human reads it.
            when = None
        if when is not None and when <= since:
            continue
        hits = sorted({w.lower() for w in WORD.findall(title)} & installed)
        if args.policy == "hold-all":
            urgent = True
        else:
            urgent = bool(hits) or bool(URGENT.search(title))
        rc = max(rc, 11 if urgent else 10)
        stamp = when.isoformat() if when else "undated"
        found.append((when or datetime.datetime.max.replace(tzinfo=datetime.timezone.utc), urgent, stamp, title, link, hits))

    for _, urgent, stamp, title, link, hits in sorted(found, key=lambda f: f[0], reverse=True):
        tag = "HOLD" if urgent else "NEWS"
        extra = f"  [installed: {', '.join(hits)}]" if hits else ""
        print(f"{tag} {stamp} {title}{extra}")
        print(f"     {link}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
