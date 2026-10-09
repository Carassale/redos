#!/usr/bin/env python3
"""Adds (or replaces) a release item at the top of a Sparkle appcast."""
import argparse
import email.utils
import html
import re
from pathlib import Path

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RedOS</title>
    <description>RedOS updates</description>
    <language>en</language>
  </channel>
</rss>
"""

parser = argparse.ArgumentParser()
parser.add_argument("appcast")
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--channel", default="")
parser.add_argument("--url", required=True)
parser.add_argument("--signature", required=True, help='sign_update output: sparkle:edSignature="..." length="..."')
parser.add_argument("--notes", required=True)
parser.add_argument("--minimum-system", default="26.0")
args = parser.parse_args()

if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', args.signature.strip()):
    raise SystemExit(f"unexpected sign_update output: {args.signature}")

path = Path(args.appcast)
appcast = path.read_text() if path.exists() else EMPTY

lines = [line.strip() for line in Path(args.notes).read_text().splitlines() if line.strip()]
notes = "".join(f"<li>{html.escape(line)}</li>" for line in lines) or "<li>Improvements and fixes.</li>"
channel = f"\n      <sparkle:channel>{args.channel}</sparkle:channel>" if args.channel else ""
item = f"""    <item>
      <title>RedOS {args.version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{args.minimum_system}</sparkle:minimumSystemVersion>{channel}
      <description><![CDATA[<ul>{notes}</ul>]]></description>
      <enclosure url="{html.escape(args.url)}" type="application/octet-stream" {args.signature.strip()}/>
    </item>
"""

# Re-running a release replaces its item.
same_build = rf"    <item>(?:(?!</item>).)*<sparkle:version>{re.escape(args.build)}</sparkle:version>.*?</item>\n"
appcast = re.sub(same_build, "", appcast, flags=re.S)
anchor = re.search(r"    <item>|  </channel>", appcast)
appcast = appcast[: anchor.start()] + item + appcast[anchor.start() :]
path.write_text(appcast)
print(f"appcast: RedOS {args.version} ({args.build}) {args.channel or 'stable'}")
