#!/bin/bash
# Builds Vitral's Wine engine from the source code CodeWeavers publishes for CrossOver (LGPL).
#   scripts/build-engine.sh          → .build/engine/wine-cx<version>.tar.xz (+ its SHA-256)
# The engine includes DXMT (Direct3D 11 on Metal) and its licenses in share/licenses.
# Runs on a Mac with Apple silicon, here and in GitHub Actions. Needs:
#   - Rosetta (Wine's macOS side is x86_64 and is built under it);
#   - from the arm64 Homebrew: mingw-w64 bison flex (native tools) and freetype gnutls sdl2
#     (only their headers, which are the same for both architectures).
# Wine opens FreeType, GnuTLS, SDL2 and MoltenVK at run time; configure only links a test against
# them. For that it uses the x86_64 copies in Gcenx's package, the same ones Vitral installs to
# run the engine (GCENX_LIBS=<folder> to use a folder already unpacked). Homebrew no longer
# runs on Intel, so there is no x86_64 Homebrew to take them from.
# Method learned from dragoshont/calimocho (LGPL-2.1-or-later) and Gcenx's builds.
set -euo pipefail
cd "$(dirname "$0")/.."

CX_VERSION=26.3.0
CX_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
CX_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz"

# DXMT (Direct3D 10/11 → Metal), MIT up to 0.80: Electron apps need it. Official release build.
DXMT_VERSION=0.80
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v$DXMT_VERSION/dxmt-v$DXMT_VERSION-builtin.tar.gz"
DXMT_SHA256=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d
DXMT_LICENSE_URL="https://raw.githubusercontent.com/3Shain/dxmt/v$DXMT_VERSION/LICENSE"

# Must match WineEngine.gcenxLibraries in VitralKit.
GCENX_URL=https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz
GCENX_SHA256=b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388

ARM=/opt/homebrew   # arm64 Homebrew
work="$PWD/.build/engine"
src="$work/src-$CX_VERSION"
build="$work/build-$CX_VERSION"
root="$work/wine-cx$CX_VERSION"            # what goes in the archive
archive="$work/wine-cx$CX_VERSION.tar.xz"
jobs=${JOBS:-$(sysctl -n hw.ncpu)}

say() { echo "[$(date +%H:%M:%S)] $*" >&2; }
fail() { say "ERROR: $*"; exit 1; }
fetch() {  # fetch <url> <sha256> <file>
    if [[ ! -f $3 ]]; then
        say "downloading $(basename "$3")"
        curl -fsSL --retry 3 -o "$3.part" "$1"
        mv "$3.part" "$3"
    fi
    local sum; sum=$(shasum -a 256 "$3" | cut -d' ' -f1)
    [[ $sum == "$2" ]] || fail "checksum mismatch for $3: $sum"
}

# --- Requirements -----------------------------------------------------------------------------
[[ $(uname -m) == arm64 ]] || fail "this script expects a Mac with Apple silicon"
arch -x86_64 /usr/bin/true 2>/dev/null || fail "Rosetta is not installed (softwareupdate --install-rosetta)"
for formula in freetype gnutls sdl2; do
    [[ -d $ARM/opt/$formula/include ]] || fail "missing the $formula headers (brew install $formula)"
done
for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    [[ -x $ARM/bin/$tool ]] || fail "missing $tool (brew install mingw-w64)"
done
[[ -x $ARM/opt/bison/bin/bison && -x $ARM/opt/flex/bin/flex ]] || fail "missing bison or flex (brew install bison flex)"

# --- Source -----------------------------------------------------------------------------------
mkdir -p "$work"
tarball="$work/crossover-sources-$CX_VERSION.tar.gz"
fetch "$CX_URL" "$CX_SHA256" "$tarball"
if [[ ! -f $src/configure ]]; then
    say "extracting Wine"
    rm -rf "$src" && mkdir -p "$src"
    tar -xzf "$tarball" -C "$src" --strip-components=2 sources/wine
fi

# --- x86_64 libraries for configure's link tests ----------------------------------------------
libs=$work/gcenx-libs   # no spaces: the paths go into -L flags
if [[ -n ${GCENX_LIBS:-} ]]; then
    rm -rf "$libs" && ln -s "$GCENX_LIBS" "$libs"
elif [[ ! -f $libs/libfreetype.dylib ]]; then
    fetch "$GCENX_URL" "$GCENX_SHA256" "$work/$(basename "$GCENX_URL")"
    rm -rf "$libs" && mkdir -p "$libs"
    tar -xJf "$work/$(basename "$GCENX_URL")" -C "$libs" --strip-components=5 \
        "Wine Stable.app/Contents/Resources/wine/lib/*.dylib"
fi
for lib in freetype gnutls SDL2 MoltenVK; do
    [[ $(lipo -archs "$libs/lib$lib.dylib" 2>/dev/null) == *x86_64* ]] || fail "no x86_64 lib$lib.dylib in $libs"
done

# --- Configure and build (x86_64 under Rosetta; the PE cross compilers stay native) ------------
export PATH="$ARM/opt/bison/bin:$ARM/opt/flex/bin:$ARM/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# No pkg-config: the arm64 one would hand out arm64 libraries. Each package is given by hand.
export PKG_CONFIG=/usr/bin/false
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CPPFLAGS
export FREETYPE_CFLAGS="-I$ARM/opt/freetype/include/freetype2" FREETYPE_LIBS="-L$libs -lfreetype"
export GNUTLS_CFLAGS="-I$ARM/opt/gnutls/include" GNUTLS_LIBS="-L$libs -lgnutls"
export SDL2_CFLAGS="-I$ARM/opt/sdl2/include/SDL2" SDL2_LIBS="-L$libs -lSDL2"
export LDFLAGS="-L$libs"   # for MoltenVK
# Xcode's clang builds for arm64 even under Rosetta: ask for x86_64 explicitly.
export CC="clang -arch x86_64" OBJC="clang -arch x86_64"
# No debug information: it would triple the engine's size.
export CFLAGS="-O2" OBJCFLAGS="-O2" CROSSCFLAGS="-O2"
export MACOSX_DEPLOYMENT_TARGET=14.0

mkdir -p "$build"
if [[ ! -f $build/Makefile ]]; then
    say "configuring (log: $build/configure.log)"
    # configure reads each library's name from otool, and Gcenx's bare install names come out
    # with a tab and version text attached: give the names it must dlopen at run time.
    (cd "$build" && arch -x86_64 "$src/configure" \
        ac_cv_lib_soname_freetype=libfreetype.6.dylib \
        ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
        --prefix=/ \
        --enable-archs=i386,x86_64 \
        --disable-tests \
        --without-x \
        --with-mingw \
        --with-freetype \
        --with-gnutls \
        --with-sdl \
        --with-vulkan \
        --with-coreaudio \
        --without-gstreamer \
        --without-fontconfig \
        --without-inotify \
        --without-opencl \
        --without-pcap \
        >configure.log 2>&1) || { tail -30 "$build/configure.log"; fail "configure failed"; }
fi
for name in FREETYPE GNUTLS SDL2 VULKAN; do
    grep -qE "^#define SONAME_LIB$name \"lib[A-Za-z0-9.-]+\.dylib\"$" "$build/include/config.h" \
        || fail "configure did not find a usable name for lib$name: $(grep "SONAME_LIB$name" "$build/include/config.h")"
done
grep -A40 "^configure: Finished" "$build/configure.log" | grep -i "warning" >&2 || true

# Build tools such as sfnt2fon link FreeType and run during the build. Gcenx's libraries have
# bare install names, which dyld also looks up in the current folder (DYLD_* variables would be
# dropped by make's /bin/sh).
for dylib in "$libs"/*.dylib; do ln -sf "$dylib" "$build/"; done

say "building with $jobs jobs (log: $build/make.log)"
arch -x86_64 make -C "$build" -j"$jobs" >"$build/make.log" 2>&1 || { tail -40 "$build/make.log"; fail "make failed"; }

say "installing into $root"
rm -rf "$root"
arch -x86_64 make -C "$build" install DESTDIR="$root" >"$build/install.log" 2>&1 || { tail -20 "$build/install.log"; fail "make install failed"; }
rm -rf "$root/share/man" "$root/include" "$root/share/applications"

say "adding DXMT $DXMT_VERSION"
dxmt="$work/dxmt-$DXMT_VERSION"
fetch "$DXMT_URL" "$DXMT_SHA256" "$work/dxmt-v$DXMT_VERSION-builtin.tar.gz"
rm -rf "$dxmt" && mkdir -p "$dxmt"
tar -xzf "$work/dxmt-v$DXMT_VERSION-builtin.tar.gz" -C "$dxmt" --strip-components=1
for dir in i386-windows x86_64-windows x86_64-unix; do
    cp "$dxmt/$dir/"* "$root/lib/wine/$dir/"
done

# Licenses and where the source code is (LGPL: whoever receives the engine can get its source).
licenses="$root/share/licenses"
mkdir -p "$licenses"
cp "$src/COPYING.LIB" "$licenses/Wine-COPYING.LIB"
cp "$src/LICENSE" "$licenses/Wine-LICENSE"
curl -fsSL --retry 3 -o "$licenses/DXMT-LICENSE" "$DXMT_LICENSE_URL"
grep -q "MIT License" "$licenses/DXMT-LICENSE" || fail "DXMT $DXMT_VERSION is not under the MIT license"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
cat >"$licenses/SOURCES.txt" <<SOURCES
Vitral Wine engine: CrossOver $CX_VERSION (Wine $(sed 's/Wine version //' "$src/VERSION")) + DXMT $DXMT_VERSION

Wine (LGPL-2.1-or-later), with CodeWeavers' changes, built unmodified from:
  $CX_URL
  SHA-256 $CX_SHA256
DXMT $DXMT_VERSION (MIT), official build:
  $DXMT_URL
  SHA-256 $DXMT_SHA256
Built with scripts/build-engine.sh of https://github.com/noctavoxfilms/vitral (commit $commit).
SOURCES
echo "CrossOver $CX_VERSION (Wine $(sed 's/Wine version //' "$src/VERSION")) + DXMT $DXMT_VERSION" >"$root/version"

# --- Check what Vitral and its programs need ----------------------------------------------------
"$root/bin/wine" --version >/dev/null 2>&1 || say "warning: bin/wine does not run here (it may need the Gcenx libraries)"
for need in lib/wine/i386-windows/user32.dll lib/wine/x86_64-windows/user32.dll lib/wine/x86_64-unix/winemac.so \
            lib/wine/x86_64-windows/d3d11.dll lib/wine/i386-windows/winemetal.dll lib/wine/x86_64-unix/winemetal.so; do
    [[ -f $root/$need ]] || fail "missing $need"
done
nm -gU "$root/lib/wine/x86_64-unix/winemac.so" | grep -q "_macdrv_functions$" || fail "winemac.so does not export macdrv_functions"

# --- Pack -------------------------------------------------------------------------------------
say "packing $archive"
tar -cJf "$archive" -C "$work" "$(basename "$root")"
shasum -a 256 "$archive" | tee "$archive.sha256"
du -sh "$root" "$archive" >&2
