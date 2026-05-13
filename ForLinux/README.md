# ShareViaLAN Linux Installer

This folder contains the Linux installer for ShareViaLAN.

Supported target: 64-bit desktop Linux with GTK 3. The installer is distro-neutral and installs the app into your user account by default, so it does not need root for the app files.

## Files

- `ShareViaLAN-linux-installer-1.0.0.sh` - self-contained installer with the app bundle inside.
- `install.sh` - small wrapper that runs the installer.
- `install-dependencies.sh` - optional helper for common runtime libraries.
- `SHA256SUMS` - checksum file for verifying the release files.

## Install

From this folder:

```bash
chmod +x install.sh ShareViaLAN-linux-installer-1.0.0.sh install-dependencies.sh
./install.sh
```

The default install location is:

```text
~/.local/opt/sharevialan
```

The launcher command is:

```bash
~/.local/bin/sharevialan
```

If `~/.local/bin` is already in your `PATH`, you can run:

```bash
sharevialan
```

## Install To Another Location

```bash
./install.sh --prefix "$HOME/Apps"
"$HOME/Apps/bin/sharevialan"
```

## Dependencies

Most modern desktop distros already have what the app needs. If the app does not start, run:

```bash
./install-dependencies.sh
```

Or install these packages manually with your distro package manager:

- GTK 3
- libayatana-appindicator or appindicator
- libsecret
- mpv runtime libraries
- xdg-utils

## Firewall

ShareViaLAN uses:

- UDP `9001` for discovery
- TCP `9002` for messages and file transfer

If devices cannot see each other, open those ports on your firewall.

Firewalld:

```bash
sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp
sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp --permanent
sudo firewall-cmd --reload
```

UFW:

```bash
sudo ufw allow 9001/udp
sudo ufw allow 9002/tcp
```

## Uninstall

Default install:

```bash
~/.local/opt/sharevialan/uninstall.sh
```

Custom prefix example:

```bash
"$HOME/Apps/opt/sharevialan/uninstall.sh"
```

## Verify Checksum

```bash
sha256sum -c SHA256SUMS
```

## Zip For GitHub

From the project root:

```bash
zip -r ForLinux.zip ForLinux
```
