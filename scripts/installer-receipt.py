#!/usr/bin/env python3
"""Bind the release DMG marker to its packaged, signed application."""
import hashlib
from pathlib import Path
import plistlib
import sys
from uuid import UUID


def write_receipt(staging: Path) -> None:
    app = staging / "Foldera.app"
    destination = staging / ".foldera-installer.plist"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "com.wtw0212.foldera" or info.get("CFBundleExecutable") != "Foldera":
        raise ValueError("The installer must contain the Foldera application")
    installer_id = str(UUID(info["FolderaInstallerID"]))
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not isinstance(version, str) or not version or not isinstance(build, str) or not build:
        raise ValueError("The installer must contain version and build metadata")
    executable = app / "Contents/MacOS/Foldera"
    if executable.is_symlink() or not executable.resolve().is_relative_to(app.resolve()):
        raise ValueError("The executable must belong to the packaged application")
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    receipt = dict(format=1, installerID=installer_id, bundleIdentifier=info["CFBundleIdentifier"],
                   version=version, build=build, executableSHA256=digest.hexdigest())
    with destination.open("xb") as output:
        plistlib.dump(receipt, output)


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("Usage: installer-receipt.py (writes only build.noindex/dmg/.foldera-installer.plist)")
    write_receipt(Path(__file__).resolve().parents[1] / "build.noindex/dmg")
