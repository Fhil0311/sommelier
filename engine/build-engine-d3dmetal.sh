#!/usr/bin/env bash
# Copyright 2026 the Sommelier project.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage: engine/build-engine-d3dmetal.sh [version]     (version defaults to 2.0.0)
#
# Builds Sommelier's Direct3D engine and writes $OUT_DIR/sommelier-engine-<version>.tar.xz, then records it in
# $OUT_DIR/engine-manifest.json. The engine holds:
#   - Wine compiled from CodeWeavers' CrossOver source. Only that tree has the pieces Apple's D3DMetal hooks into
#     (the Mac driver's function table, ntdll's unix-call export and the libd3dshared loader), which stock Wine
#     and the 1.x engine lack. D3DMetal itself is never part of the engine: the app copies it out of the user's own
#     Game Porting Toolkit download (SommelierKit's D3DMetalStore).
#   - DXMT (Direct3D 10/11 on Metal) in lib/dxmt, which a single game opts into through engine/dll-path-shim, with
#     our d3d12.dll beside it that answers "no Direct3D 12 here" (engine/d3d12-stub): a game on DXMT that probes
#     Direct3D 12 would otherwise crash inside D3DMetal's.
#   - GStreamer from the project's official macOS packages (LGPL parts only), so Media Foundation can play videos.
#   - The x86_64 runtime libraries (FreeType, GnuTLS, SDL2, MoltenVK) from the same pinned build the 1.x engine uses.
# Every download is checked against a pinned SHA-256; no prebuilt Wine is used.
#
# Environment:
#   CACHE_DIR          downloads                              (default engine/.cache/dl)
#   WORK_DIR           build tree                             (default engine/.cache/cx)
#   OUT_DIR            archive and manifest                   (default engine/dist)
#   MANIFEST_BASE_URL  where the archive will be published    (default file:// URL of OUT_DIR)
#   RESUME=1           reuse a configured build tree in WORK_DIR, e.g. after fixing a compile error
#   SUPPORT_EMAIL      contact for LGPL source requests, written into the engine's notice
# Requires Xcode, Rosetta and: brew install bison pkgconf freetype gnutls sdl2 mingw-w64
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ENGINE_DIR"

die() { echo "error: $*" >&2; exit 1; }

# Creates a folder if needed and prints its absolute path (relative paths are taken from engine/).
absolute_dir() { mkdir -p "$1" && (cd "$1" && pwd); }

ENGINE_VERSION="${1:-2.0.0}"
DL_DIR="$(absolute_dir "${CACHE_DIR:-.cache/dl}")"
BUILD_ROOT="$(absolute_dir "${WORK_DIR:-.cache/cx}")"
DIST_DIR="$(absolute_dir "${OUT_DIR:-dist}")"

# ---- Pinned inputs ----------------------------------------------------------------------------------------------
CROSSOVER_RELEASE=26.3.0
CROSSOVER_TARBALL="crossover-sources-${CROSSOVER_RELEASE}.tar.gz"
CROSSOVER_SOURCE_URL="https://media.codeweavers.com/pub/crossover/source/${CROSSOVER_TARBALL}"
CROSSOVER_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872

# Runtime libraries only; build-engine.sh pins the same archive.
GCENX_TARBALL=wine-staging-11.18-osx64.tar.xz
GCENX_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/${GCENX_TARBALL}"
GCENX_SHA256=b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127

# Our DXMT fork (upstream v0.80 plus pipeline records, warm-up and quiet frame statistics; branch sommelier/warmup),
# built the way upstream's CI does it. engine/.cache/dxmt-toolchain holds that toolchain; see the fork's DEVELOPMENT.md.
DXMT_TAG=v0.80-sommelier.3
DXMT_TARBALL="dxmt-${DXMT_TAG}-builtin.tar.gz"
DXMT_RELEASE_URL="https://github.com/Fhil0311/sommelier-dxmt/releases/download/${DXMT_TAG}/${DXMT_TARBALL}"
DXMT_SHA256=4de6c2019a9151656b8e45b63d6d2049573ba2e857bdfec55bd9ce3f96a7cd59

# GStreamer's universal macOS packages (only the x86_64 slices end up in the engine).
GSTREAMER_RELEASE=1.28.8
GSTREAMER_PKG_BASE="https://gstreamer.freedesktop.org/data/pkg/osx/${GSTREAMER_RELEASE}"
GST_RUNTIME_PKG="gstreamer-1.0-${GSTREAMER_RELEASE}-universal.pkg"
GST_RUNTIME_URL="${GSTREAMER_PKG_BASE}/${GST_RUNTIME_PKG}"
GST_RUNTIME_SHA256=d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe
GST_DEVEL_PKG="gstreamer-1.0-devel-${GSTREAMER_RELEASE}-universal.pkg"
GST_DEVEL_URL="${GSTREAMER_PKG_BASE}/${GST_DEVEL_PKG}"
GST_DEVEL_SHA256=e6d380bc17be7eccf13e0154567d4718fc9321da822408c7ca0cd808b3d4a3f7
# Package components merged into the build prefix. The GPL ones (codecs-gpl, dvd-gpl, codecs-gpl-restricted) are
# deliberately absent.
GST_COMPONENTS=(
  base-system-1.0 base-crypto gstreamer-1.0-core gstreamer-1.0-codecs gstreamer-1.0-codecs-restricted
  gstreamer-1.0-libav gstreamer-1.0-playback gstreamer-1.0-effects
)
# License folders copied next to the bundled GStreamer.
GST_LICENSE_DIRS=(
  gstreamer-1.0 gst-plugins-base-1.0 gst-plugins-bad-1.0 ffmpeg glib orc libogg libvorbis libtheora opus mpg123
  pcre2 proxy-libintl
)

SUPPORT_EMAIL="${SUPPORT_EMAIL:-support@playsommelier.com}"

# ---- Build tree layout ------------------------------------------------------------------------------------------
GST_PREFIX="$BUILD_ROOT/gst/prefix"
RUNTIME_ROOT="$BUILD_ROOT/runtime"
LINK_DEPS="$BUILD_ROOT/deps"
WINE_SOURCE="$BUILD_ROOT/sources/wine"
WINE_BUILD="$BUILD_ROOT/build"
WINE_STAGE="$BUILD_ROOT/stage"
ENGINE_TREE="$BUILD_ROOT/engine"
WINE_TREE="$ENGINE_TREE/wine"
RUNTIME_LIB=""      # set by unpack_runtime_libraries
BREW_PREFIX=""      # set by check_prerequisites
CLEAN_ENV=()        # set by check_prerequisites

check_prerequisites() {
  if [[ "$SUPPORT_EMAIL" == SUPPORT-EMAIL-NOT-SET ]]; then
    echo "warning: SUPPORT_EMAIL is not set; this engine must not be published" >&2
  fi
  command -v x86_64-w64-mingw32-gcc >/dev/null || die "mingw-w64 is missing (brew install mingw-w64)"
  BREW_PREFIX="$(brew --prefix)"
  [[ -x "$BREW_PREFIX/opt/bison/bin/bison" ]] || die "bison 3 or newer is missing (brew install bison)"
  # Wine is configured and compiled with nothing from the caller's environment except HOME.
  CLEAN_ENV=(/usr/bin/env -i "HOME=$HOME" "PATH=$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
             MACOSX_DEPLOYMENT_TARGET=14.0)
}

# Downloads <file> from <url> into the cache unless it is already there, then checks it against <sha256>.
# A file that fails the check is renamed to <file>.bad so the next run downloads it again.
download_pinned() {
  local file="$1" url="$2" expected="$3"
  local dest="$DL_DIR/$file"
  if [[ ! -f "$dest" ]]; then
    curl --fail --location --retry 3 --silent --show-error --output "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  local actual
  actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    mv "$dest" "$dest.bad"
    die "$file does not match its pinned checksum (renamed to $file.bad)"
  fi
}

download_inputs() {
  download_pinned "$CROSSOVER_TARBALL" "$CROSSOVER_SOURCE_URL" "$CROSSOVER_SHA256"
  download_pinned "$GCENX_TARBALL" "$GCENX_URL" "$GCENX_SHA256"
  download_pinned "$DXMT_TARBALL" "$DXMT_RELEASE_URL" "$DXMT_SHA256"
  download_pinned "$GST_RUNTIME_PKG" "$GST_RUNTIME_URL" "$GST_RUNTIME_SHA256"
  download_pinned "$GST_DEVEL_PKG" "$GST_DEVEL_URL" "$GST_DEVEL_SHA256"
}

# Expands both GStreamer packages and merges the chosen components into one prefix that Wine compiles against.
# The prefix is relocatable (its .pc files are relative to pcfiledir), so it is kept between runs.
prepare_gstreamer_prefix() {
  local marker_pc="$GST_PREFIX/lib/pkgconfig/gstreamer-1.0.pc"
  [[ -f "$marker_pc" ]] && return 0
  local scratch="$BUILD_ROOT/gst"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  pkgutil --expand-full "$DL_DIR/$GST_RUNTIME_PKG" "$scratch/runtime"
  pkgutil --expand-full "$DL_DIR/$GST_DEVEL_PKG" "$scratch/devel"
  mkdir -p "$GST_PREFIX"
  local component candidate
  for component in "${GST_COMPONENTS[@]}"; do
    # Development parts are named either "<name>-devel" or, for "*-1.0" components, "<name without -1.0>-devel".
    for candidate in "$scratch/runtime/${component}-${GSTREAMER_RELEASE}-universal.pkg" \
                     "$scratch/devel/${component%-1.0}-devel-${GSTREAMER_RELEASE}-universal.pkg" \
                     "$scratch/devel/${component}-devel-${GSTREAMER_RELEASE}-universal.pkg"; do
      if [[ -d "$candidate/Payload" ]]; then
        cp -R "$candidate/Payload/." "$GST_PREFIX/"
      fi
    done
  done
  [[ -f "$marker_pc" ]] || die "the GStreamer prefix is incomplete ($marker_pc is missing)"
}

# Copies the runtime libraries out of the pinned Gcenx build and makes link-time copies for configure.
unpack_runtime_libraries() {
  rm -rf "$RUNTIME_ROOT"
  mkdir -p "$RUNTIME_ROOT"
  tar -xJf "$DL_DIR/$GCENX_TARBALL" -C "$RUNTIME_ROOT"
  local found=("$RUNTIME_ROOT"/*.app/Contents/Resources/wine/lib)
  [[ -d "${found[0]}" ]] || die "no wine/lib folder in $GCENX_TARBALL"
  RUNTIME_LIB="${found[0]}"

  rm -rf "$LINK_DEPS"
  mkdir -p "$LINK_DEPS/lib" "$LINK_DEPS/include"
  # Each copy gets an @rpath id naming the versioned file, so the modules Wine builds record the versioned name.
  local link_name versioned copy
  while read -r link_name versioned; do
    copy="$LINK_DEPS/lib/$link_name.dylib"
    cp "$RUNTIME_LIB/$versioned.dylib" "$copy"
    chmod u+w "$copy"
    install_name_tool -id "@rpath/$versioned.dylib" "$copy" 2>/dev/null
  done <<'LIBRARIES'
libgnutls libgnutls.30
libfreetype libfreetype.6
libSDL2 libSDL2-2.0.0
libvulkan libvulkan.1
libMoltenVK libMoltenVK
LIBRARIES

  # Headers come from Homebrew; the libraries above are what the engine actually loads.
  local formula header_dir
  while read -r formula header_dir; do
    ln -s "$BREW_PREFIX/opt/$formula/include/$header_dir" "$LINK_DEPS/include/$header_dir"
  done <<'HEADERS'
freetype freetype2
gnutls gnutls
sdl2 SDL2
HEADERS
}

# Unpacks CrossOver's Wine, applies engine/patches/*.patch and runs configure in a fresh build folder.
configure_wine() {
  rm -rf "$WINE_SOURCE" "$WINE_BUILD"
  tar -xzf "$DL_DIR/$CROSSOVER_TARBALL" -C "$BUILD_ROOT" sources/wine
  local patch_file
  for patch_file in "$ENGINE_DIR"/patches/*.patch; do
    [[ -f "$patch_file" ]] || continue
    (cd "$WINE_SOURCE" && patch -p1 --forward --silent <"$patch_file") || die "could not apply $patch_file"
  done
  mkdir -p "$WINE_BUILD"

  local options=(
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin "--prefix=$WINE_STAGE"
    --enable-archs=i386,x86_64 --disable-tests --disable-win16
  )
  local feature
  for feature in mingw freetype gnutls sdl vulkan coreaudio opencl unwind gstreamer; do
    options+=("--with-$feature")
  done
  for feature in x wayland alsa oss udev v4l2 capi inotify pulse dbus netapi krb5 gssapi fontconfig sane gphoto \
                 ffmpeg usb; do
    options+=("--without-$feature")
  done

  local gst_cflags="-I$GST_PREFIX/include/gstreamer-1.0 -I$GST_PREFIX/include/glib-2.0 -I$GST_PREFIX/lib/glib-2.0/include"
  # Spelled out instead of asking pkg-config, whose output would add an rpath into this machine's prefix.
  local gst_libs="-L$GST_PREFIX/lib" lib
  for lib in gstvideo-1.0 gstaudio-1.0 gsttag-1.0 gstbase-1.0 gstreamer-1.0 gobject-2.0 glib-2.0 intl; do
    gst_libs+=" -l$lib"
  done

  local x86="-arch x86_64"
  # errexit does not apply inside a subshell on the left of ||, hence the explicit &&.
  (
    cd "$WINE_BUILD" &&
    "${CLEAN_ENV[@]}" \
      CC="clang $x86" CXX="clang++ $x86" OBJC="clang $x86" \
      FREETYPE_CFLAGS="-I$LINK_DEPS/include/freetype2" FREETYPE_LIBS="-L$LINK_DEPS/lib -lfreetype" \
      GNUTLS_CFLAGS="-I$LINK_DEPS/include" GNUTLS_LIBS="-L$LINK_DEPS/lib -lgnutls" \
      SDL2_CFLAGS="-I$LINK_DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$LINK_DEPS/lib -lSDL2" \
      GSTREAMER_CFLAGS="$gst_cflags" GSTREAMER_LIBS="$gst_libs" \
      LDFLAGS="-L$LINK_DEPS/lib -Wl,-rpath,@loader_path/../../" \
      ../sources/wine/configure "${options[@]}" >configure.out 2>&1
  ) || die "configure failed; see $WINE_BUILD/configure.out"
}

compile_wine() {
  # Tools run during the build (sfnt2fon needs FreeType) carry the same @loader_path/../../ rpath as Wine's
  # modules. Seen from build/tools/<tool>/ that is the build folder itself, so the libraries go there.
  cp -a "$RUNTIME_LIB"/*.dylib "$WINE_BUILD/"
  rm -rf "$WINE_STAGE"
  local jobs
  jobs="$(sysctl -n hw.ncpu)"
  (
    cd "$WINE_BUILD" &&
    "${CLEAN_ENV[@]}" make -j"$jobs" >make.out 2>&1 &&
    "${CLEAN_ENV[@]}" make install >install.out 2>&1
  ) || die "building Wine failed; see $WINE_BUILD/make.out and $WINE_BUILD/install.out"
}

# Checks that the staged Wine can find its libraries on another Mac and holds no path into this build tree.
verify_wine_tree() {
  # Wine loads FreeType, GnuTLS and friends by leaf name; dyld finds them only through the rpath set in LDFLAGS
  # (wine/lib, as in the 1.x engine). Without it fonts and TLS break at run time, not at build time.
  local module load_commands
  for module in ntdll win32u bcrypt winebus; do
    load_commands="$(otool -l "$WINE_TREE/lib/wine/x86_64-unix/$module.so")"
    grep -qF "path @loader_path/../../ " <<<"$load_commands" || die "$module.so lacks the @loader_path/../../ rpath"
  done
  local dylib
  for dylib in libfreetype.6 libgnutls.30 libSDL2-2.0.0 libvulkan.1; do
    [[ -f "$WINE_TREE/lib/$dylib.dylib" ]] || die "runtime library $dylib.dylib is missing"
  done
  # The loader also keeps the configure prefix as plain text to compute relative paths; that one is harmless.
  local binary references
  for binary in "$WINE_TREE/bin/wine" "$WINE_TREE/bin/wineserver" "$WINE_TREE"/lib/wine/x86_64-unix/*; do
    if [[ -L "$binary" ]]; then continue; fi
    references="$(otool -L "$binary" | tail -n +2; otool -l "$binary" | grep -A2 LC_RPATH || true)"
    if grep -qF "$BUILD_ROOT" <<<"$references"; then
      die "$binary refers to the build folder"
    fi
  done
}

# DXMT lives outside Wine's DLL folder; a game opts in with SOMMELIER_DLL_PREPEND (engine/dll-path-shim).
add_dxmt() {
  local unpacked="$BUILD_ROOT/dxmt" dest="$WINE_TREE/lib/dxmt"
  rm -rf "$unpacked"
  mkdir -p "$unpacked" "$dest"
  tar -xzf "$DL_DIR/$DXMT_TARBALL" -C "$unpacked"
  cp -R "$unpacked/$DXMT_TAG/"* "$dest/"
  # winemetal.so looks for these two next to itself (@loader_path).
  local neighbour
  for neighbour in winemac ntdll; do
    ln -sf "../../wine/x86_64-unix/$neighbour.so" "$dest/x86_64-unix/$neighbour.so"
  done
  local required
  for required in x86_64-windows/winemetal.dll i386-windows/winemetal.dll x86_64-unix/winemetal.so; do
    [[ -f "$dest/$required" ]] || die "DXMT is missing $required"
  done
  add_d3d12_stub "$dest"
}

# Wine only takes a DLL from its library folders when the file says it is a Wine builtin: the 16-byte signature
# right after the DOS header, where winebuild puts it. Ours are built with mingw, so it is written here.
mark_builtin() {
  python3 - "$1" <<'PY'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
if struct.unpack_from("<I", data, 0x3C)[0] < 0x40 + 17: sys.exit(f"{path}: no room for the builtin signature")
data[0x40:0x40 + 17] = b"Wine builtin DLL\0"
open(path, "wb").write(data)
PY
}

# A Direct3D 12 that says it isn't there, for games on DXMT (engine/d3d12-stub/d3d12.c says why). Next to DXMT's
# DLLs, so only a game that opted into DXMT loads it; exported with Windows' ordinals, as plugins import by number.
add_d3d12_stub() {
  local dest="$1" flags="-shared -nostdlib -nostartfiles -O2 -Wall -s"
  x86_64-w64-mingw32-gcc $flags -o "$dest/x86_64-windows/d3d12.dll" d3d12-stub/d3d12.c d3d12-stub/d3d12.def \
    -Wl,--kill-at -Wl,-e,DllMain -lkernel32
  i686-w64-mingw32-gcc $flags -o "$dest/i386-windows/d3d12.dll" d3d12-stub/d3d12.c d3d12-stub/d3d12.def \
    -Wl,--kill-at -Wl,--enable-stdcall-fixup -Wl,-e,_DllMain@12 -lkernel32
  local arch
  for arch in x86_64 i386; do
    mark_builtin "$dest/$arch-windows/d3d12.dll"
    x86_64-w64-mingw32-objdump -p "$dest/$arch-windows/d3d12.dll" | grep -q "101.*D3D12CreateDevice" \
      || die "the $arch d3d12 stub doesn't export D3D12CreateDevice as ordinal 101"
  done
}

# Media Foundation playback: the plugins games need, their libraries and the plugin scanner, plus their licenses.
add_gstreamer() {
  local winegstreamer="$WINE_TREE/lib/wine/x86_64-unix/winegstreamer.so"
  [[ -f "$winegstreamer" ]] || die "winegstreamer.so was not built (configure did not find GStreamer); see $WINE_BUILD/configure.out"
  python3 tools/gst-bundle.py "$GST_PREFIX" "$winegstreamer" "$WINE_TREE"
  local required
  for required in lib/gstreamer-1.0/libgstlibav.dylib lib/gstreamer-1.0/libgstasf.dylib lib/libgstreamer-1.0.0.dylib \
                  libexec/gstreamer-1.0/gst-plugin-scanner; do
    [[ -f "$WINE_TREE/$required" ]] || die "the GStreamer bundle is missing $required"
  done
  local licenses="$ENGINE_TREE/licenses/gstreamer" name
  mkdir -p "$licenses"
  for name in "${GST_LICENSE_DIRS[@]}"; do
    if [[ -d "$GST_PREFIX/share/licenses/$name" ]]; then
      cp -R "$GST_PREFIX/share/licenses/$name" "$licenses/"
    fi
  done
}

# Our two small helpers: the DLL path shim (CrossOver's Wine dlopens x86_64-unix/cxcompatdb.so at start; ours only
# prepends DLL folders) and the Chromium helper wrapper that keeps Steam's web UI on software rendering.
add_helpers() {
  clang -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib -O2 -Wall \
    -o "$WINE_TREE/lib/wine/x86_64-unix/cxcompatdb.so" dll-path-shim/shim.c
  x86_64-w64-mingw32-gcc -municode -mwindows -static -O2 -Wall \
    -o "$ENGINE_TREE/steamwebhelper-wrapper.exe" steamwebhelper-wrapper/wrapper.c
}

# License texts, the notice, and the scripts and patches that produced this build (the LGPL asks for the
# scripts used to control compilation to travel with the binaries).
add_notices() {
  local build_files="$ENGINE_TREE/licenses/build"
  mkdir -p "$build_files"
  cp licenses/* "$ENGINE_TREE/licenses/"
  cp build-engine-d3dmetal.sh manifest-add.py steamwebhelper-wrapper/wrapper.c dll-path-shim/shim.c \
     d3d12-stub/d3d12.c d3d12-stub/d3d12.def tools/gst-bundle.py patches/*.patch "$build_files/"

  cat >"$ENGINE_TREE/licenses/NOTICE.txt" <<NOTICE
Sommelier engine $ENGINE_VERSION. Third-party software and licenses: THIRD-PARTY-NOTICES.md (this folder).
Wine (LGPL-2.1+), built from CodeWeavers' CrossOver $CROSSOVER_RELEASE source: $CROSSOVER_SOURCE_URL
  (sha256 $CROSSOVER_SHA256). That tarball is also published with this engine's release.
  The Sommelier project's changes to it are the patches in build/ (*.patch), applied by the build script:
  winemac-sommelier.patch - the Mac driver shows GDI-drawn child windows above a window's Metal view, and counts
  presented frames (Metal and OpenGL) for Sommelier's frame statistics and in-game counter (written only when
  SOMMELIER_FRAME_STATS_DIR is set); a program with ShowInDock=n (AppDefaults) gets no Dock icon, and a game run
  from its Sommelier shortcut app keeps that app's icon.
  ntdll-dock-names.patch - the link a program runs through (and so its Dock name) drops ".exe", and takes the
  name from the list in SOMMELIER_APP_NAMES when the program is in it, running from inside the game's shortcut app
  when the list gives one.
  loader-game-category.patch - the loader's built-in Info.plist carries the games category, so macOS Game Mode
  engages for a game running from inside its shortcut app.
  winemac-no-tray.patch - with SOMMELIER_NO_TRAY=1 the environment's tray icons (Steam's, the EA app's) don't go
  to the Mac's menu bar; programs are told they did.
  winemac-display-modes.patch - without Retina mode, display modes larger than the desktop (the display's unscaled
  pixels) aren't listed: borderless games named them as their resolution, full-screen ones switched the Mac to them.
  ntdll-exe-redirect.patch - a recipe may start one program in place of another (a game instead of its
  launcher): the table named by SOMMELIER_EXE_REDIRECTS, read at each process creation.
  ntdll-exe-redirect.z1-env.patch - programs from a folder named in SOMMELIER_EXE_ENV's table get that folder's own variables
    (a game's graphics: DXMT or D3DMetal, Turbo, SDR), so a store needn't restart for them.
  ntdll-exe-redirect.z2-args.patch - programs named in SOMMELIER_EXE_ARGS's table get arguments added to their command line
    (a recipe's arguments for a game a store starts, such as Ubisoft Connect, which can't pass any).
  ntdll-hide-wine.patch - with SOMMELIER_HIDE_WINE=1, GetProcAddress(ntdll, "wine_get_version") and the other
  Wine version exports aren't found, as on Windows (some games switch features off when they are).
  winecoreaudio-no-mic.patch - with SOMMELIER_NO_MIC=1 a program sees no microphone (Sommelier sets it for store
  clients, so macOS asks for the microphone only when a game opens it).
  winegstreamer-sommelier.patch - with GStreamer 1.28 a decoder's pad appears before its caps are set; the parser
  takes the pad's current caps when there are any and treats unfixed raw caps as "no format yet".
  winegstreamer-video-sysmem.patch - with SOMMELIER_VIDEO_SYSMEM=1 the H.264 decoder isn't D3D aware and offers
  NV12 in system memory, which callers that take NV12 only (Unreal's Electra player) need for menu videos. The
  idea comes from winevideo (https://github.com/Jfishin/winevideo); the code is ours.
  win32u-rawinput-unlocked-enum.patch - the raw input device list is rebuilt without holding its lock, so a thread
  suspended while it asks a device (Wine can suspend one inside a system call) no longer stops every other thread.
  ntdll-rosetta-cpu-fidelity.patch, ntdll-rosetta-smc-cpuid.patch - from MacGameFix by Mathias Kowoll
  (https://github.com/MathiasKowoll/MacGameFix, patches 0017 and 0019; 0017 written by Hrava, as MacGameFix
  credits), unchanged, under the GPL-3.0-or-later: Rosetta 2
  behaving as an x86 CPU does for copy protection (CPUID, debug registers, faults, a CPUID skipped after
  self-modifying code). With them, ntdll.so as a whole is under the GPL-3.0 (licenses/GPL-3.0.txt).
GStreamer $GSTREAMER_RELEASE (LGPL-2.1+), from the project's macOS packages: $GST_RUNTIME_URL (sha256 $GST_RUNTIME_SHA256),
  $GST_DEVEL_URL (sha256 $GST_DEVEL_SHA256). The engine carries the plugins Wine's Media Foundation uses, the libraries
  they need (GLib, FFmpeg's libav* built LGPL, Orc, Ogg/Vorbis/Theora/Opus, mpg123, PCRE2) and the plugin scanner,
  all unmodified, x86_64 slices only; which plugins: build/gst-bundle.py. Licenses: licenses/gstreamer/. No part
  of the packages that is under the GPL is included.
DXMT $DXMT_TAG (LGPL-2.1+): upstream v0.80 (https://github.com/3Shain/dxmt) with the Sommelier project's
  changes (pipeline records, warm-up, frame statistics; files carry change notices): $DXMT_RELEASE_URL (sha256 $DXMT_SHA256).
  Modified source: https://github.com/Fhil0311/sommelier-dxmt/tree/$DXMT_TAG
  lib/dxmt also holds the Sommelier project's own d3d12.dll (build/d3d12.c), which reports no Direct3D 12 to
  games on DXMT; it contains no DXMT or Wine code.
  The build script is in build/ (build-engine-d3dmetal.sh), with the runtime pins it uses.
No Apple software is included. DirectX 12 uses Apple's D3DMetal, which Sommelier copies from the user's own
  download of Apple's Game Porting Toolkit; the user's use of it is governed by Apple's license.
Source offer: $SUPPORT_EMAIL, for at least three years (see THIRD-PARTY-NOTICES.md).
NOTICE

  cat >"$ENGINE_TREE/ENGINE.json" <<ENGINE_JSON
{ "version": "$ENGINE_VERSION", "wineVersion": "11.0, from CrossOver $CROSSOVER_RELEASE source", "backends": ["d3dMetal", "dxmt"], "minMacOS": "14.0" }
ENGINE_JSON
}

assemble_engine() {
  rm -rf "$ENGINE_TREE"
  mkdir -p "$ENGINE_TREE"
  cp -R "$WINE_STAGE" "$WINE_TREE"
  # Headers, man pages, desktop files and static archives are only useful for building against Wine.
  rm -rf "$WINE_TREE/include" "$WINE_TREE/share/man" "$WINE_TREE/share/applications"
  find "$WINE_TREE/lib/wine" -name '*.a' -delete
  cp -a "$RUNTIME_LIB"/*.dylib "$WINE_TREE/lib/"
  verify_wine_tree
  add_dxmt
  add_gstreamer
  add_helpers
  add_notices
}

package_engine() {
  local archive_name="sommelier-engine-$ENGINE_VERSION.tar.xz"
  local archive="$DIST_DIR/$archive_name"
  local manifest="$DIST_DIR/engine-manifest.json"
  rm -f "$archive"
  XZ_OPT="-T0 -6" tar -cJf "$archive" -C "$ENGINE_TREE" .
  local digest size
  digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
  size="$(stat -f%z "$archive")"
  ./manifest-add.py "$manifest" "$ENGINE_VERSION" "${MANIFEST_BASE_URL:-file://$DIST_DIR}/$archive_name" \
    "$digest" "$size" d3dMetal,dxmt
  printf 'engine:   %s (%d MB)\nsha256:   %s\nmanifest: %s\n' "$archive" "$((size / 1048576))" "$digest" "$manifest"
}

check_prerequisites
download_inputs
prepare_gstreamer_prefix
unpack_runtime_libraries
if [[ "${RESUME:-0}" != 1 || ! -f "$WINE_BUILD/Makefile" ]]; then
  configure_wine
fi
compile_wine
assemble_engine
package_engine
