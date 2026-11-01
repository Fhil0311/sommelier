#!/usr/bin/env python3
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
# Bundles the GStreamer pieces winegstreamer needs out of the official macOS framework packages: the plugins named
# below, the transitive closure of the libraries they and winegstreamer.so link, and the plugin scanner helper,
# all thinned to x86_64 (Wine runs under Rosetta). Libraries the engine already has (zlib, bzip2, gettext) are kept.
#   gst-bundle.py <gstreamer prefix> <winegstreamer.so> <engine wine folder>
import os, shutil, subprocess, sys

PREFIX, WINEGST, WINE = sys.argv[1:4]
# What Wine's parser and transforms build pipelines from (decodebin, converters) and the demuxers/decoders of the
# formats games ship (MP4/H.264/AAC, WMV/WMA in ASF, Ogg/Vorbis/Theora/Opus, MP3, WAV, AVI, Matroska/WebM).
PLUGINS = ("coreelements app audioconvert audioresample videoconvertscale typefindfunctions playback deinterlace "
           "videofilter videorate audiorate asf isomp4 matroska avi wavparse audioparsers videoparsersbad libav "
           "vorbis ogg opus theora id3demux mpg123 pbtypes").split()

def deps(f):
    out = subprocess.run(["otool", "-L", f], capture_output=True, text=True, check=True).stdout.splitlines()[1:]
    return [l.split()[0][len("@rpath/"):] for l in out if l.strip().startswith("@rpath/")]

def thin(src, dst):
    if subprocess.run(["lipo", src, "-thin", "x86_64", "-output", dst], capture_output=True).returncode != 0:
        shutil.copy2(src, dst)

plugins_dir = os.path.join(WINE, "lib", "gstreamer-1.0")
os.makedirs(plugins_dir, exist_ok=True)
seen, queue = set(), [WINEGST]
for p in PLUGINS:
    f = os.path.join(PREFIX, "lib", "gstreamer-1.0", f"libgst{p}.dylib")
    if not os.path.exists(f): sys.exit(f"gst-bundle: plugin missing from the packages: {p}")
    queue.append(f)
while queue:
    f = queue.pop(0); base = os.path.basename(f)
    if base in seen: continue
    seen.add(base)
    if f != WINEGST:
        dst = os.path.join(plugins_dir, base) if "/gstreamer-1.0/" in f else os.path.join(WINE, "lib", base)
        if f.startswith(PREFIX) and not (os.path.exists(dst) and "/gstreamer-1.0/" not in f): thin(f, dst)
    for d in deps(f):
        if d in seen: continue
        src = os.path.join(PREFIX, "lib", d)
        if os.path.exists(src): queue.append(src)
        elif not os.path.exists(os.path.join(WINE, "lib", d)) and d not in ("ntdll.so", "winegstreamer.so"):
            sys.exit(f"gst-bundle: {d} (needed by {base}) is in neither the packages nor the engine")
scanner = os.path.join(PREFIX, "libexec", "gstreamer-1.0", "gst-plugin-scanner")
os.makedirs(os.path.join(WINE, "libexec", "gstreamer-1.0"), exist_ok=True)
thin(scanner, os.path.join(WINE, "libexec", "gstreamer-1.0", "gst-plugin-scanner"))
print(f"gst-bundle: {len(os.listdir(plugins_dir))} plugins, {len(seen)} modules seen")
