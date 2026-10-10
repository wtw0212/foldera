#!/usr/bin/env python3
"""Write the Sparkle appcast for one release DMG.

Foldera reads the appcast from https://github.com/<repo>/releases/latest/download/appcast.xml, so each release
carries a feed listing only itself. Sparkle installs the DMG only if its EdDSA signature matches SUPublicEDKey.

Usage: make-appcast.py REPO VERSION BUILD DMG SIGNATURE OUTPUT
"""
import base64
import binascii
from pathlib import Path
import re
import sys
from xml.sax.saxutils import escape, quoteattr

MINIMUM_SYSTEM_VERSION = "26.0"


def make_appcast(repo: str, version: str, build: str, dmg: Path, signature: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Repository must be OWNER/NAME")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must be MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    if dmg.name != f"Foldera-{version}.dmg" or not dmg.is_file() or dmg.is_symlink():
        raise ValueError(f"Expected the release image Foldera-{version}.dmg")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError
    except (binascii.Error, ValueError):
        raise ValueError("Signature must be a base64 Ed25519 signature") from None
    release = f"https://github.com/{repo}/releases/tag/v{version}"
    url = f"https://github.com/{repo}/releases/download/v{version}/{dmg.name}"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Foldera</title>
    <link>{escape(f"https://github.com/{repo}/releases")}</link>
    <item>
      <title>Foldera {escape(version)}</title>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>{escape(release)}</sparkle:fullReleaseNotesLink>
      <enclosure url={quoteattr(url)} length="{dmg.stat().st_size}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
"""


if __name__ == "__main__":
    if len(sys.argv) != 7:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    repo, version, build, dmg, signature, output = sys.argv[1:]
    try:
        feed = make_appcast(repo, version, build, Path(dmg), signature.strip())
    except ValueError as error:
        raise SystemExit(str(error))
    Path(output).write_text(feed, encoding="utf-8")
