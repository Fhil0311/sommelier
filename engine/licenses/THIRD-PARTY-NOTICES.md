# Sommelier game engines: third-party software

Sommelier's engines are made of the free and open-source software below. Each component keeps its own license; the
full texts are the other files in this folder. Two small pieces are the Sommelier project's own code, © the Sommelier
project, all rights reserved: the Chromium helper wrapper (`steamwebhelper-wrapper.exe`) and the DLL path shim
(`cxcompatdb.so`, `engine/dll-path-shim`).

**No Apple software is included in any Sommelier engine.** DirectX 12 support uses Apple's D3DMetal, which Sommelier copies
from the user's own download of Apple's Game Porting Toolkit; the user's use of it is governed by Apple's license.

## Source code

- **Wine in engine 2.x** is built by us from CodeWeavers' CrossOver 26.3.0 source (`crossover-sources-26.3.0.tar.gz`)
  with our changes applied as patches (`licenses/build/*.patch` in the engine; from 2.2.1 the Mac driver shows
  GDI-drawn child windows above a window's Metal view, from 2.2.2 it also counts presented frames for Sommelier's
  frame statistics). That tarball, the patches and our build script are published
  next to the engine on its release page.
- **Wine Staging in engine 1.x** and the **runtime libraries** in both engines (everything under "Runtime libraries"
  below) are Gcenx's macOS builds, version 11.18: https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18
  (libraries built with MacPorts; their sources are MacPorts' distfiles for those versions).
- **DXMT** in engine 2.0 and 2.1: the unmodified v0.80 release build, https://github.com/3Shain/dxmt/releases/tag/v0.80
  (source: https://github.com/3Shain/dxmt/tree/v0.80). From engine 2.2: v0.80 with our changes (pipeline records,
  shader warm-up, frame statistics), built from https://github.com/Fhil0311/sommelier-dxmt (tags v0.80-sommelier.N).
- **DXVK** in engine 1.x: https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507-repack

**Written offer.** For at least three years after we last distribute an engine, anyone who received it can ask us
for the complete corresponding source code of any LGPL or GPL component in it, for no more than the cost of
providing it: email the support address given in the engine's NOTICE.txt.

## Components

| Component | Engine | License | Text |
|---|---|---|---|
| Wine (CodeWeavers CrossOver 26.3.0 source) | 2.x | LGPL-2.1-or-later | Wine-COPYING.LIB.txt, Wine-LICENSE.txt |
| Wine Staging 11.18 | 1.x | LGPL-2.1-or-later | Wine-COPYING.LIB.txt, Wine-LICENSE.txt |
| DXVK (macOS, async) 1.10.3 | 1.x | zlib | DXVK-LICENSE.txt |
| DXMT v0.80 | 2.x | LGPL-2.1-or-later | DXMT-LICENSE.txt, LGPL-2.1.txt |
| MoltenVK | both | Apache-2.0 | MoltenVK-LICENSE.txt |
| Vulkan Loader | both | Apache-2.0 | Vulkan-Loader-LICENSE.txt |
| SDL2 | both | zlib | SDL2-LICENSE.txt |
| FreeType | both | FreeType License (FTL) | freetype-LICENSE.txt |
| GStreamer 1.28.8 (core, plugins base/good/bad/ugly subset, libav) | 2.x (from 2.3) | LGPL-2.1-or-later | gstreamer/ (per component), LGPL-2.1.txt |
| FFmpeg libav*, libsw* (through gst-libav; built without GPL parts) | 2.x (from 2.3) | LGPL-2.1-or-later | gstreamer/ffmpeg/ |
| GLib, GObject, GModule, GIO | 2.x (from 2.3) | LGPL-2.1-or-later | gstreamer/glib/ |
| Orc | 2.x (from 2.3) | BSD-2-Clause | gstreamer/orc/ |
| libogg, libvorbis, libtheora, Opus | 2.x (from 2.3) | BSD-3-Clause | gstreamer/libogg/, gstreamer/libvorbis/, gstreamer/libtheora/, gstreamer/opus/ |
| mpg123 | 2.x (from 2.3) | LGPL-2.1-or-later | gstreamer/mpg123/ |
| PCRE2 | 2.x (from 2.3) | BSD-3-Clause | gstreamer/pcre2/ |
| MacGameFix Rosetta patches 0017 (by Hrava), 0019, by Mathias Kowoll (in ntdll.so; https://github.com/MathiasKowoll/MacGameFix) | 2.x (from 2.2.5) | GPL-3.0-or-later (ntdll.so as a whole then GPL-3.0) | GPL-3.0.txt |

### Runtime libraries (both engines)

| Library | License | Text |
|---|---|---|
| GnuTLS | LGPL-2.1-or-later | gnutls-COPYING.LESSERv2.txt |
| Nettle, Hogweed | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | nettle-COPYING.LESSERv3.txt, GPL-3.0.txt |
| GMP | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | gmp-COPYING.LESSERv3.txt, GPL-3.0.txt |
| libtasn1 | LGPL-2.1-or-later | libtasn1-COPYING.LESSERv2.txt |
| libidn2 | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | libidn2-COPYING.LESSERv3.txt, GPL-3.0.txt |
| libunistring | LGPL-3.0-or-later or GPL-2.0-or-later | libunistring-COPYING.LIB.txt, GPL-3.0.txt |
| libiconv, libcharset | LGPL-2.1-or-later | LGPL-2.1.txt |
| libintl (gettext runtime) | LGPL-2.1-or-later | LGPL-2.1.txt |
| p11-kit | BSD-3-Clause | p11-kit-COPYING.txt |
| ICU 76 | Unicode License v3 | icu-LICENSE.txt |
| libxml2 | MIT | libxml2-Copyright.txt |
| libxslt, libexslt | MIT | libxslt-Copyright.txt |
| libffi | MIT | libffi-LICENSE.txt |
| libinotify-kqueue | MIT | libinotify-kqueue-LICENSE.txt |
| libpng | libpng License | libpng-LICENSE.txt |
| zlib | zlib | zlib-LICENSE.txt |
| bzip2 | bzip2 License (BSD-style) | bzip2-LICENSE.txt |
| xz (liblzma) | 0BSD | xz-COPYING.txt, xz-COPYING.0BSD.txt |
| lz4 | BSD-2-Clause | lz4-LICENSE.txt |
| zstd | BSD-3-Clause | zstd-LICENSE.txt |
| Brotli | MIT | brotli-LICENSE.txt |
| libpcap | BSD-3-Clause | libpcap-LICENSE.txt |
| MacPorts legacy support | Various, per source file (including APSL-2.0) | macports-legacy-support-LICENSE.txt; source: https://github.com/macports/macports-legacy-support |
