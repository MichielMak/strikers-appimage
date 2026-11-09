#!/usr/bin/env bash
# Build a self-contained AppImage of new-coke/strikers (Linux x86_64 or aarch64).
#
# The release tarball is unpacked into AppDir/opt/strikers unchanged. The Qt 6
# settings app gets Qt 6.4 and its dependencies from Debian 12 (bookworm), so
# the AppImage runs on glibc 2.35+ hosts without the distro's Qt installed.
#
# Needs: bash, curl, apt-get, dpkg-deb, python3. No root, no FUSE, no docker.
#
# Usage: ./build.sh [strikers-linux-<arch>.tar.gz]
#   ARCH=x86_64|aarch64  target, default: this machine (build natively, the
#                        bundled patchelf and appimagetool run on the target arch)
#   TAG=v1.9.7           upstream release to download, default: latest
#   VERSION=...          version in the file name, default: TAG or today's date
#   OUTDIR=...           where the AppImage goes, default: this folder
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  x86_64)        DEB_ARCH=amd64; TRIPLET=x86_64-linux-gnu;  UPSTREAM_ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64; DEB_ARCH=arm64; TRIPLET=aarch64-linux-gnu; UPSTREAM_ARCH=arm64 ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 1 ;;
esac
TAG="${TAG:-}"
BUILD="$HERE/build/$ARCH"
APPDIR="$BUILD/AppDir"
if [ -n "$TAG" ]; then
  RELEASE_URL="https://github.com/new-coke/strikers/releases/download/$TAG/strikers-linux-$UPSTREAM_ARCH.tar.gz"
else
  RELEASE_URL="https://github.com/new-coke/strikers/releases/latest/download/strikers-linux-$UPSTREAM_ARCH.tar.gz"
fi
# Pinned releases with checksums, not the moving "continuous" builds, so every
# AppImage is packed the same way.
TOOL_VERSION=1.9.1
RUNTIME_VERSION=20251108
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/$TOOL_VERSION/appimagetool-$ARCH.AppImage"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-$ARCH"
case "$ARCH" in
  x86_64)
    TOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64)
    TOOL_SHA256=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    RUNTIME_SHA256=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
esac

# Libraries the host must provide (AppImage excludelist, plus the GPU/audio
# stack, which has to match the host's drivers).
EXCLUDE=(
  ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 libanl.so.1 libBrokenLocale.so.1 libc.so.6 libdl.so.2 libm.so.6 libmvec.so.1
  libnss_compat.so.2 libnss_dns.so.2 libnss_files.so.2 libpthread.so.0 libresolv.so.2 librt.so.1
  libthread_db.so.1 libutil.so.1 libstdc++.so.6 libgcc_s.so.1 libz.so.1
  libGL.so.1 libEGL.so.1 libGLdispatch.so.0 libGLX.so.0 libOpenGL.so.0 libdrm.so.2 libglapi.so.0
  libgbm.so.1 libvulkan.so.1 libxcb.so.1 libX11.so.6 libX11-xcb.so.1 libwayland-client.so.0
  libwayland-cursor.so.0 libwayland-egl.so.1 libasound.so.2 libfontconfig.so.1 libfreetype.so.6
  libharfbuzz.so.0 libcom_err.so.2 libexpat.so.1 libgpg-error.so.0 libICE.so.6 libSM.so.6
  libusb-1.0.so.0 libuuid.so.1 libjack.so.0 libpipewire-0.3.so.0 libxcb-dri3.so.0 libxcb-dri2.so.0
  libfribidi.so.0 libgmp.so.10 libudev.so.1 libdbus-1.so.3
)

# Qt plugins worth shipping for a small widgets app.
QT_PLUGINS=(platforms platformthemes platforminputcontexts imageformats iconengines xcbglintegrations
  wayland-decoration-client wayland-graphics-integration-client wayland-shell-integration)

mkdir -p "$BUILD/tools" "$BUILD/release"

# --- 1. release tarball -------------------------------------------------------
TARBALL="${1:-}"
if [ -z "$TARBALL" ]; then
  TARBALL="$BUILD/release/strikers-linux-$UPSTREAM_ARCH.tar.gz"
  echo ">> downloading $RELEASE_URL"
  curl -fSL -o "$TARBALL" "$RELEASE_URL"
fi

# --- 2. Debian 12 Qt 6 ---------------------------------------------------------
APTROOT="$BUILD/apt"
SYSROOT="$BUILD/sysroot"
apt_() {
  apt-get -o Dir="$APTROOT" -o Dir::State::status="$APTROOT/var/lib/dpkg/status" \
    -o Dir::Cache="$APTROOT/var/cache/apt" -o Dir::Cache::archives="$APTROOT/var/cache/apt/archives" -o Debug::NoLocking=1 -o Acquire::Languages=none \
    -o APT::Architecture=$DEB_ARCH "$@"
}
if [ ! -d "$SYSROOT/usr/lib/$TRIPLET/qt6/plugins/platforms" ]; then
  echo ">> fetching Qt 6 from Debian 12"
  mkdir -p "$APTROOT"/{etc/apt/preferences.d,etc/apt/sources.list.d,etc/apt/trusted.gpg.d,var/lib/apt/lists/partial,var/cache/apt/archives/partial,var/lib/dpkg}
  touch "$APTROOT/var/lib/dpkg/status"
  echo "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm main" \
    > "$APTROOT/etc/apt/sources.list"
  apt_ update -q
  apt_ -y -q --download-only --no-install-recommends install \
    libqt6widgets6 qt6-qpa-plugins qt6-wayland qt6-gtk-platformtheme libqt6svg6 qt6-image-formats-plugins patchelf
  rm -rf "$SYSROOT"; mkdir -p "$SYSROOT"
  for d in "$APTROOT"/var/cache/apt/archives/*.deb; do dpkg-deb -x "$d" "$SYSROOT"; done
fi
PATCHELF="$SYSROOT/usr/bin/patchelf"

# --- 3. appimagetool + runtime ------------------------------------------------
# fetch <url> <sha256> <file>: GitHub release downloads time out now and then,
# hence the retries; a file that does not match its checksum is refused.
fetch() {
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then return 0; fi
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 -o "$3" "$1"
  if ! echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then
    echo "$1 does not match its pinned SHA-256" >&2
    rm -f "$3"
    exit 1
  fi
}
fetch "$TOOL_URL" "$TOOL_SHA256" "$BUILD/tools/appimagetool"
fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$BUILD/tools/runtime"
chmod +x "$BUILD/tools/appimagetool"

# --- 4. AppDir -----------------------------------------------------------------
echo ">> assembling AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/opt/strikers" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" "$APPDIR/usr/share/metainfo"
tar xzf "$TARBALL" -C "$APPDIR/opt/strikers"
[ -x "$APPDIR/opt/strikers/strikers" ] || { echo "tarball has no ./strikers" >&2; exit 1; }

QTPLUG="$SYSROOT/usr/lib/$TRIPLET/qt6/plugins"
for p in "${QT_PLUGINS[@]}"; do
  [ -d "$QTPLUG/$p" ] && cp -a "$QTPLUG/$p" "$APPDIR/usr/plugins/"
done

# Copy the shared-library closure of the settings app and the plugins out of
# the sysroot, skipping anything on the exclude list.
python3 -I - "$SYSROOT/usr/lib/$TRIPLET:$SYSROOT/lib/$TRIPLET" "$APPDIR/usr/lib" "${EXCLUDE[*]}" \
  "$APPDIR/opt/strikers/strikers-settings" $(find "$APPDIR/usr/plugins" -name '*.so') <<'PY'
import os, shutil, subprocess, sys
libdirs, out, exclude, roots = sys.argv[1].split(":"), sys.argv[2], set(sys.argv[3].split()), sys.argv[4:]
def needed(path):
    r = subprocess.run(["readelf", "-d", path], capture_output=True, text=True, check=True).stdout
    return [l.split("[", 1)[1].rstrip("]") for l in r.splitlines() if "(NEEDED)" in l]
seen, todo, missing = set(), list(roots), set()
while todo:
    for lib in needed(todo.pop()):
        if lib in seen or lib in exclude:
            continue
        seen.add(lib)
        src = next((os.path.join(d, lib) for d in libdirs if os.path.exists(os.path.join(d, lib))), None)
        if src is None:
            missing.add(lib); continue
        dst = os.path.join(out, lib)
        shutil.copy2(os.path.realpath(src), dst)
        todo.append(dst)
print(f"   bundled {len(seen) - len(missing)} libraries")
if missing:
    sys.exit("missing from sysroot: " + " ".join(sorted(missing)))
PY

# RUNPATHs: libs find each other, plugins and the settings app find the libs.
for f in "$APPDIR"/usr/lib/*.so*; do "$PATCHELF" --set-rpath '$ORIGIN' "$f"; done
find "$APPDIR/usr/plugins" -name '*.so' -exec "$PATCHELF" --set-rpath '$ORIGIN/../../lib' {} \;
"$PATCHELF" --set-rpath '$ORIGIN/../../usr/lib' "$APPDIR/opt/strikers/strikers-settings"

cat > "$APPDIR/opt/strikers/qt.conf" <<'EOF'
[Paths]
Prefix = ../../usr
Plugins = plugins
EOF

install -m755 "$HERE/AppRun" "$APPDIR/AppRun"
cp "$HERE/strikers.desktop" "$APPDIR/strikers.desktop"
cp "$HERE/strikers.desktop" "$APPDIR/usr/share/applications/io.github.new_coke.strikers.desktop"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp "$HERE/strikers.png" "$APPDIR/strikers.png"
cp "$HERE/strikers.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/strikers.png"
cp "$HERE/strikers.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/strikers.svg"
ln -s strikers.png "$APPDIR/.DirIcon"

# Report the glibc floor of everything we ship.
FLOOR=$(find "$APPDIR/usr" "$APPDIR/opt/strikers" -type f \( -name '*.so*' -o -perm -u+x \) -exec objdump -T {} + 2>/dev/null \
  | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1 || true)
echo "   needs host $FLOOR or newer"

# --- 5. pack -------------------------------------------------------------------
VERSION="${VERSION:-${TAG:-$(date +%Y%m%d)}}"
OUTDIR="${OUTDIR:-$HERE}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/Super_Mario_Strikers-$VERSION-$ARCH.AppImage"
echo ">> packing $OUT"
ARCH=$ARCH VERSION=$VERSION "$BUILD/tools/appimagetool" --appimage-extract-and-run \
  --runtime-file "$BUILD/tools/runtime" --no-appstream "$APPDIR" "$OUT"
echo ">> done: $OUT"
