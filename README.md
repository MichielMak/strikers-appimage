# Super Mario Strikers AppImage

Repackages the Linux x86_64 and aarch64 releases of [new-coke/strikers](https://github.com/new-coke/strikers/wiki/Linux)
as one AppImage. You still supply your own disc image.

## Build

Download a ready AppImage from [Releases](../../releases). They are built automatically.

```sh
./build.sh                          # latest stable release, for this machine's arch
TAG=v1.9.7 ./build.sh               # a specific upstream release
ARCH=aarch64 ./build.sh             # must run on an aarch64 machine
./build.sh strikers-linux-x86_64.tar.gz
```

Needs `curl`, `apt-get`, `dpkg-deb`, `python3`, `readelf`/`objdump`. No root, FUSE or docker.
The result needs glibc 2.35 or newer on the host.

## Use

```sh
./Super_Mario_Strikers-*.AppImage            # settings app: Disc Image..., then Play
./Super_Mario_Strikers-*.AppImage --game     # start the game directly
./Super_Mario_Strikers-*.AppImage --udev     # print the GameCube adapter udev rule
```

- Config: `~/.config/strikers/strikers.ini`, seeded from `strikers.ini.example` on first run.
  The AppImage is read-only, so the ini cannot live beside the game. `STRIKERS_CONFIG` overrides it.
- Saves: `~/.local/share/Super Mario Strikers`, same as the tarball.

## How it works

- The release tarball goes unchanged into `AppDir/opt/strikers`. The game binary only links
  libc, libm and libz and loads SDL's video/audio backends from the host, so it needs nothing bundled.
- The settings app needs Qt 6.4 or newer. `build.sh` fetches Qt 6.4.2 from Debian 12 with an
  unprivileged `apt-get` (signed with the host's Debian keyring) and copies the settings app's
  library closure, minus the AppImage excludelist (glibc, libstdc++, GL/EGL, X11/xcb, Wayland
  client, fontconfig, freetype, dbus, udev). Host GPU and audio drivers have to match the host,
  so those stay unbundled.
- `patchelf` sets RUNPATHs so the bundled Qt is found without `LD_LIBRARY_PATH`. That keeps the
  game, which the settings app starts, from inheriting the bundled libraries.
- `qt.conf` beside the settings app points Qt at the bundled plugins (xcb, wayland, gtk3 theme).

## Automatic releases

`.github/workflows/appimage.yml` runs every 6 hours. It compares the newest 5 upstream releases
with the releases in this repo. For each missing one it builds x86_64 (on `ubuntu-24.04`) and
aarch64 (on `ubuntu-24.04-arm`) and publishes both under the upstream tag. Upstream prereleases
stay prereleases here, and only upstream's latest stable release is marked latest.

Upstream ships its own AppImages since [new-coke/strikers#49](https://github.com/new-coke/strikers/pull/49).
Tags where upstream has both (`strikers-linux-x86_64.AppImage` and `strikers-linux-arm64.AppImage`)
are skipped, so this repo only builds when upstream's AppImage step failed or for older releases.
A manual run with a tag always builds.

Rebuild one tag by hand: Actions, "AppImage per upstream release", Run workflow, enter the tag.
