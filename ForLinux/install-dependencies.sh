#!/usr/bin/env bash
set -euo pipefail

print_help() {
  cat <<'EOF'
Install common Linux runtime libraries needed by ShareViaLAN.

Usage:
  ./install-dependencies.sh

Supported package managers:
  apt, dnf, yum, zypper, pacman

The app itself installs per-user with ShareViaLAN-linux-installer-1.0.0.sh.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y \
    libgtk-3-0 \
    libayatana-appindicator3-1 \
    libsecret-1-0 \
    libmpv2 \
    xdg-utils
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y \
    gtk3 \
    libayatana-appindicator-gtk3 \
    libsecret \
    mpv-libs \
    xdg-utils
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y \
    gtk3 \
    libappindicator-gtk3 \
    libsecret \
    mpv-libs \
    xdg-utils
elif command -v zypper >/dev/null 2>&1; then
  sudo zypper install -y \
    gtk3 \
    libayatana-appindicator3-1 \
    libsecret-1-0 \
    libmpv2 \
    xdg-utils
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed \
    gtk3 \
    libayatana-appindicator \
    libsecret \
    mpv \
    xdg-utils
else
  cat >&2 <<'EOF'
Could not detect apt, dnf, yum, zypper, or pacman.

Install these runtime libraries with your distro package manager:
  GTK 3, libayatana-appindicator/appindicator, libsecret, mpv, xdg-utils
EOF
  exit 1
fi

echo "Dependency install step completed."
