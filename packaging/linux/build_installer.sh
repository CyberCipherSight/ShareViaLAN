#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="sharevialan"
DISPLAY_NAME="ShareViaLAN"
BUNDLE_EXECUTABLE="lancom"
OUT_DIR="$PROJECT_ROOT/dist/linux"
STUB_FILE="$SCRIPT_DIR/linux_installer_stub.sh"
BUNDLE_DIR="$PROJECT_ROOT/build/linux/x64/release/bundle"
ICON_SOURCE="$PROJECT_ROOT/Items/ShareViaLan.jpg"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_version() {
  local version_line
  version_line="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+).*$/\1/p' "$PROJECT_ROOT/pubspec.yaml" | head -n 1)"

  if [[ -z "$version_line" ]]; then
    echo "Unable to read app version from pubspec.yaml" >&2
    exit 1
  fi

  printf '%s\n' "${version_line%%+*}"
}

require_command flutter
require_command tar
require_command magick

if [[ ! -f "$STUB_FILE" ]]; then
  echo "Installer stub not found: $STUB_FILE" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon not found: $ICON_SOURCE" >&2
  exit 1
fi

VERSION="$(read_version)"
INSTALLER_PATH="$OUT_DIR/${DISPLAY_NAME}-linux-installer-${VERSION}.sh"
TMP_DIR="$(mktemp -d)"
PAYLOAD_ARCHIVE="$TMP_DIR/payload.tar.gz"
PAYLOAD_DIR="$TMP_DIR/payload"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$PAYLOAD_DIR/${APP_NAME}-bundle"

echo "Building Flutter Linux release bundle..."
flutter build linux --release

if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Linux bundle not found: $BUNDLE_DIR" >&2
  exit 1
fi

cp -a "$BUNDLE_DIR/." "$PAYLOAD_DIR/${APP_NAME}-bundle/"
magick "$ICON_SOURCE" \
  -resize 104% \
  -gravity center \
  -crop 1024x1024+0+0 \
  +repage \
  -resize 512x512 \
  -strip \
  "$PAYLOAD_DIR/app_icon.png"
printf '%s\n' "$BUNDLE_EXECUTABLE" > "$PAYLOAD_DIR/bundle_executable.txt"

mkdir -p "$OUT_DIR"
tar -czf "$PAYLOAD_ARCHIVE" -C "$PAYLOAD_DIR" .

cat "$STUB_FILE" "$PAYLOAD_ARCHIVE" > "$INSTALLER_PATH"
chmod +x "$INSTALLER_PATH"

echo "Linux installer created:"
echo "  $INSTALLER_PATH"
