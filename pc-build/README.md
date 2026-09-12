# Windows build environment for FUTO Keyboard (local PC)

Command-line setup, build, and install for a Windows PC — **no Android Studio
required**. It automatically installs whatever the build needs (JDK, Android
SDK, NDK, CMake) and then compiles the app and installs it to phones connected
over USB or Wi-Fi. The design mirrors the launcher/build scripts proven in the
sibling **GT** project.

The idea: after one `setup-android.cmd`, the machine has (mostly) everything it
needs, and every later `build-android.cmd` just compiles and pushes to your
phones. Re-running `setup-android.cmd` is safe — it only installs what is
missing.

## Quick start

```
setup-android.cmd            One-time: JDK 17 + Android SDK/NDK/CMake + submodules
build-android.cmd            Build the unstable DEBUG APK and install it to phones
a.bat                        git pull, then build-android.cmd (args pass through)
```

Run these from the **repo root** (the `.cmd`/`.bat` wrappers live there; the
PowerShell scripts they call live in this `pc-build/` folder). In fact
`setup-android.cmd` is optional as a separate step — `build-android.cmd` (and
`a.bat`) run it automatically when the environment isn't set up (see below), so
on a fresh machine you can just run `a.bat`.

## `setup-android.cmd` — one-time toolchain setup

Installs, checking before acting so re-runs are safe:

1. **Microsoft OpenJDK 17** via winget (skipped if any JDK 17+ is found). AGP
   8.10 / Gradle 8.14 need JDK 17+.
2. **Android command-line tools** into `%LOCALAPPDATA%\Android\Sdk`. If the
   pinned download URL 404s (Google rotates the build number), get the current
   "Command line tools only" zip from <https://developer.android.com/studio>
   and update the URL in `pc-build/setup.ps1`.
3. SDK licenses + `platform-tools`, `platforms;android-35`, `build-tools;35.0.0`,
   **`ndk;28.2.13676358`** and **`cmake;3.22.1`** — the NDK version matches
   `build.gradle`'s `ndkVersion` and the CMake version matches the native code's
   `cmake_minimum_required`. (These match `.ci/Dockerfile`, so a local build
   uses the same toolchain the CI does.) `-Emulator` also installs the emulator
   and an Android 35 system image.
4. `local.properties` (repo root) pointing Gradle at the SDK — no env vars.
5. **Git submodules** (`git submodule update --init --recursive`). The build
   needs them (keyboard layouts, `libs/` .aar dependencies, voice/swipe models,
   translations, themes, large resources). Some are hosted on gitlab.futo.org /
   Hugging Face; if one can't be fetched, setup names it and continues — re-run
   when you have access, or fetch it manually.

No signing keystore is generated: **`java/shared.keystore` is already checked
in** and signs the debug build (and the release build when there is no
`keystore.properties`), so every build installs over the previous one on your
phones with no extra step. Only publishing an official release needs your own
key + a `keystore.properties`.

## `build-android.cmd` — build + install

```
build-android.cmd             unstable DEBUG APK (default) -> Desktop, then adb install
build-android.cmd -Release    unstable RELEASE APK (minified) instead
build-android.cmd -Stable     the "stable" flavor
build-android.cmd -Playstore  the "playstore" flavor
build-android.cmd -NoInstall  build + Desktop copy only, skip adb
```

It is self-healing — if the environment isn't set up, it runs
`setup-android.cmd` for you rather than failing:

- missing `local.properties` → runs setup first;
- no JDK 17+ found → runs setup (which installs OpenJDK 17), then continues;
- empty submodule folder → fetches submodules;
- **the Gradle build itself fails** (e.g. a missing NDK/CMake or unaccepted
  licence on a machine that never ran setup) → runs setup to repair the
  environment and **retries the build once**. If it still fails after setup,
  that's a real build error and it's reported as such.

`a.bat` is the everyday shorthand: it runs `git pull` first (best-effort — a
failed pull, e.g. offline or with local changes, just warns and builds the
current checkout) and then calls `build-android.cmd`. Every switch below works
with either (`a -Release`, `a -NoInstall`, …). Use `build-android.cmd` directly
when you want to build **without** pulling.

The build derives a version from git (like the CI does): `versionCode` from
`git rev-list --first-parent --count master`, `versionName` from
`git describe --tags` (or `0.0.0-r<count>-<hash>` when there are no tags). It
then:

- copies the APK to your **Desktop** as `FUTO-Keyboard-<version>[-debug].apk`;
- runs `adb install -r` to every phone connected over USB with **USB debugging**
  enabled (Settings → Developer options), or over wireless debugging.

Because the `versionCode` climbs with every commit, a newer build installs
cleanly over the previous one, keeping app data.

### Choosing / naming your phones

- **Which devices get the build** — copy `push-devices.example.txt` to
  `push-devices.txt` (gitignored) and list one adb target per line: a USB serial
  or a wireless `host:port` (connected first). With no such file, the build
  installs to whatever single phone is connected.
- **Friendly names in the log** — copy `device-names.example.txt` to
  `device-names.txt` (gitignored) and write `<serial or fragment> = <name>` per
  line. A fragment matches too, which keeps wireless devices named across
  re-pairs. Unnamed devices fall back to the phone's own name, then model, then
  serial.

**Other phones:** send them the Desktop APK file (email, chat, drive, USB) and
open it on the phone — allow "install from unknown sources" once.

## `run-emulator.cmd` — emulator (optional, best-effort)

```
setup-android.cmd -Emulator   # once
run-emulator.cmd              # creates the "futokbd" AVD on first run, then boots it
```

A USB phone is the primary test target; the emulator is a convenience. With
Hyper-V/WSL2 enabled Windows accelerates it automatically (WHPX); otherwise
install Google's AEHD driver.

## Files here

```
pc-build/
├── setup.ps1                    JDK + SDK/NDK/CMake + local.properties + submodules
├── build.ps1                    version stamp + gradle assemble + Desktop copy + adb install
├── emulator.ps1                 create/boot the "futokbd" AVD
├── device-names.example.txt     template -> device-names.txt  (friendly names)
└── push-devices.example.txt     template -> push-devices.txt  (which devices to install to)
```

The repo-root wrappers `setup-android.cmd`, `build-android.cmd`, and
`run-emulator.cmd` just invoke these under PowerShell (preferring pwsh 7 when
installed); `a.bat` runs `git pull` and then `build-android.cmd`.
