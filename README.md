# ShareViaLAN

ShareViaLAN is an open-source Flutter app for sharing files and messages between
Android, Linux, and Windows devices on the same Wi-Fi, hotspot, or LAN. Transfers
go directly between devices without a cloud file server. The app contains no
advertising SDK or ad display.

ShareViaLAN is available under the [MIT license](LICENSE). You may use, modify,
fork, redistribute, and sell copies, including for commercial purposes, while
preserving the copyright and license notice. Contributions are welcome through
pull requests and are reviewed by the maintainer before merging. See
[Licensing](LICENSING.md) for license history and third-party exceptions.

- [Android on Google Play](https://play.google.com/store/apps/details?id=com.cybersight.sharefilevialan)
- [Android testing opt-in](https://play.google.com/apps/testing/com.cybersight.sharefilevialan)
- [Desktop releases](https://github.com/CyberCipherSight/ShareViaLAN/releases)
- [Report a bug](https://github.com/CyberCipherSight/ShareViaLAN/issues)

Google Play availability depends on the release track, account, and country.
Source version 1.0.7 does not imply that every download has that version. The
repository's existing 1.0.0 desktop installers are older builds.

## Build from source

Install Flutter **3.41.4** (the tested version) and the native build tools for your
platform, then:

```bash
git clone https://github.com/CyberCipherSight/ShareViaLAN.git
cd ShareViaLAN
flutter pub get
flutter analyze
flutter test
```

- Linux: install Clang, CMake, Ninja, pkg-config, GTK 3 development headers, and
  libstdc++ development headers; run `flutter build linux --release`.
- Windows: install Visual Studio's **Desktop development with C++** workload;
  run `flutter build windows --release` on Windows.
- Android: install JDK 17 and the Android SDK (API 36); run
  `flutter build apk --debug` for a development build. Store releases require
  your own signing key as described below.

The Linux bundle is in `build/linux/x64/release/bundle/`; keep the entire bundle
together. The Windows bundle is in `build/windows/x64/runner/Release/`.
Use `flutter doctor` to check native dependencies. iOS, macOS, and web directories
are retained as Flutter scaffolding; they are not supported release targets.

See [Contributing](CONTRIBUTING.md) for build checks and
[Security](SECURITY.md) for privacy and reporting guidance.

See [Architecture](docs/ARCHITECTURE.md) for the discovery, messaging, storage,
and platform integration layout.

Android 1.0.7 release-quality changes and remaining upstream compatibility
references are documented in [Android release quality](docs/ANDROID_RELEASE_QUALITY.md).

## Opening received files

Tap **Open** on a completed transfer to open it with an installed application.
On Android, opening an APK for the first time opens the system **Allow from this
source** screen for ShareViaLAN. Enable it and return to continue to the Android
installer. If permission is declined, tap **Open** again when ready. Android still
asks you to confirm installation; device management restrictions can prevent it.
Other file types use temporary read access for the viewer. Android 6–9 requests
storage permission when saving received files to public Downloads.

On Linux and Windows, received files go into the system's configured
`Downloads/ShareViaLAN` folder, including relocated or localized Downloads
folders. Files need an installed viewer or installer for their format. Linux
scripts can be run explicitly with `bash /path/to/installer.sh`; the app does not
automatically mark received files executable or run them when a transfer finishes.

The source contains no advertising SDK, premium section, or remote ad fetch.
Internal peer IDs support discovery and chat history and are not displayed in
Settings.

The portable filename checks, relocated Downloads-folder support, clearer file
opening errors, and updated file picker apply to Linux and Windows too.
Android edge-to-edge, APK permissions, and R8 changes are Android-specific.

## Android Release Signing

The Android release build reads signing credentials from `android/key.properties`.
Keep that file and the keystore private; both are ignored by the Android
`.gitignore`.

Generate an upload key:

```bash
cd android
keytool -genkeypair -v \
  -keystore upload-keystore.jks \
  -storetype JKS \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

Create `android/key.properties` from the example and fill in the passwords you
entered for the keystore:

```properties
storePassword=your-keystore-password
keyPassword=your-key-password
keyAlias=upload
storeFile=upload-keystore.jks
```

Build the Google Play upload artifact:

```bash
flutter build appbundle --release
```

Output:

```text
build/app/outputs/bundle/release/app-release.aab
```

## Desktop Installers

Android packaging is already in place. The installer setup in this project now
covers Windows and Linux desktop builds.

### Windows installer

Build the Windows release and package it into a native `.exe` installer with
Inno Setup 6:

```powershell
powershell -ExecutionPolicy Bypass -File packaging/windows/build_installer.ps1
```

Output:

```text
dist/windows/ShareViaLAN-Setup-<version>.exe
```

Requirements:

- Run this on Windows.
- Install Flutter with Windows desktop support enabled.
- Install Inno Setup 6 so `ISCC.exe` is available.

### Linux Download And Install

Use a Linux installer from the [Releases page](https://github.com/CyberCipherSight/ShareViaLAN/releases)
when one is available, or build the current source with the instructions below.

1. Open the GitHub repository in your browser.
2. Go to **Releases**.
3. Download the file named like this:

```text
ShareViaLAN-linux-installer-<version>.sh
```

4. Open a terminal in the folder where the file was downloaded.
5. Make the installer executable:

```bash
chmod +x ShareViaLAN-linux-installer-<version>.sh
```

6. Install it for your current Linux user:

```bash
./ShareViaLAN-linux-installer-<version>.sh
```

The installer places the app under `~/.local/opt/sharevialan`, creates the
`sharevialan` command in `~/.local/bin`, and adds a desktop launcher named
`ShareViaLAN`.

If `sharevialan` is not found in your terminal after installation, add
`~/.local/bin` to your `PATH` or launch the app from your desktop app menu.

To uninstall:

```bash
~/.local/opt/sharevialan/uninstall.sh
```

If peers cannot connect, allow ShareViaLAN's local-network ports in your Linux
firewall:

```bash
sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp
```

Or, on Ubuntu systems using `ufw`:

```bash
sudo ufw allow 9001/udp
sudo ufw allow 9002/tcp
```

### Build The Linux Installer

Project maintainers can build a self-contained Linux installer script with:

```bash
bash packaging/linux/build_installer.sh
```

Output:

```text
dist/linux/ShareViaLAN-linux-installer-<version>.sh
```

Install the locally built installer for the current user:

```bash
bash dist/linux/ShareViaLAN-linux-installer-<version>.sh
```

Install to a custom prefix:

```bash
bash dist/linux/ShareViaLAN-linux-installer-<version>.sh --prefix /opt/sharevialan-root
```

Upload the generated `.sh` file from `dist/linux/` to the GitHub release so Linux
users can download it directly.
