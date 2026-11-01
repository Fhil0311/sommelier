#!/usr/bin/env python3
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Records one engine build in engine-manifest.json and signs it (engine-manifest.json.sig). An entry with the same version is replaced; all other
entries stay. A missing manifest is created with Sommelier's default Steam arguments.

    manifest-add.py <manifest> <version> <url> <sha256> <size> <backend>[,<backend>...]
"""
import json
import os
import subprocess
import sys


def version_key(version):
    # Numeric parts compare as numbers and sort before text parts, so 2.0.10 follows 2.0.9.
    return [(0, int(part), "") if part.isdigit() else (1, 0, part)
            for part in version.replace("-", ".").split(".")]


def main(argv):
    if len(argv) != 7:
        sys.exit(__doc__.strip())
    manifest_path, version, url, digest, size, backends = argv[1:]
    if os.path.exists(manifest_path):
        with open(manifest_path) as source:
            manifest = json.load(source)
    else:
        manifest = {"engines": [], "steamArgs": ["-no-cef-sandbox", "-noverifyfiles"], "knownIssues": {}}

    entry = {"version": version, "url": url, "sha256": digest, "size": int(size),
             "minAppVersion": "0.1", "backends": backends.split(",")}
    kept = [existing for existing in manifest["engines"] if existing["version"] != version]
    manifest["engines"] = sorted(kept + [entry], key=lambda item: version_key(item["version"]))

    with open(manifest_path, "w") as target:
        json.dump(manifest, target, indent=2)
        target.write("\n")
    # Signed next to it (engine-manifest.json.sig): apps take only a list the owner signed, and its checksums are
    # what every engine download is checked against. Upload both files together.
    sign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "sign.sh")
    signature = subprocess.run([sign, manifest_path], check=True, capture_output=True, text=True).stdout.strip()
    with open(manifest_path + ".sig", "w") as target:
        target.write(signature + "\n")


if __name__ == "__main__":
    main(sys.argv)
