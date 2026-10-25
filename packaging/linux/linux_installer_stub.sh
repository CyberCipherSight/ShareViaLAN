#!/usr/bin/env bash
set -euo pipefail

APP_NAME="sharevialan"
DISPLAY_NAME="ShareViaLAN"
APP_COMMENT="Local Area Network Communication App"
STARTUP_WM_CLASS="com.cybersight.sharefilevialan"
BUNDLE_EXECUTABLE="lancom"
DEFAULT_PREFIX="$HOME/.local"

print_help() {
  cat <<'EOF'
ShareViaLAN Linux installer

Usage:
  ./ShareViaLAN-linux-installer.sh [--prefix <directory>] [--help]

Options:
  --prefix <directory>  Install under a custom prefix. Defaults to ~/.local.
  --help                Show this help text.
EOF
}

PREFIX="$DEFAULT_PREFIX"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --prefix" >&2
        exit 1
      fi
      PREFIX="$1"
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$PREFIX" == "~" ]]; then
  PREFIX="$HOME"
elif [[ "$PREFIX" == "~/"* ]]; then
  PREFIX="${HOME}/${PREFIX#~/}"
elif [[ "$PREFIX" != /* ]]; then
  PREFIX="$(pwd)/$PREFIX"
fi

APP_DIR="$PREFIX/opt/$APP_NAME"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/512x512/apps"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

ARCHIVE_LINE="$(awk '/^__ARCHIVE_BELOW__$/ { print NR + 1; exit 0; }' "$0")"

if [[ -z "$ARCHIVE_LINE" ]]; then
  echo "Installer payload is missing." >&2
  exit 1
fi

mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
tail -n +"$ARCHIVE_LINE" "$0" | tar -xzf - -C "$TMP_DIR"

if [[ ! -d "$TMP_DIR/${APP_NAME}-bundle" ]]; then
  echo "Installer payload is corrupt." >&2
  exit 1
fi

if [[ -f "$TMP_DIR/bundle_executable.txt" ]]; then
  BUNDLE_EXECUTABLE="$(head -n 1 "$TMP_DIR/bundle_executable.txt")"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$TMP_DIR/${APP_NAME}-bundle/." "$APP_DIR/"
install -m 644 "$TMP_DIR/app_icon.png" "$ICON_DIR/${APP_NAME}.png"

cat > "$BIN_DIR/$APP_NAME" <<EOF
#!/usr/bin/env sh
exec "$APP_DIR/$BUNDLE_EXECUTABLE" "\$@"
EOF
chmod 755 "$BIN_DIR/$APP_NAME"

cat > "$DESKTOP_DIR/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
Comment=$APP_COMMENT
Exec=$BIN_DIR/$APP_NAME %U
Icon=$APP_NAME
Terminal=false
Categories=Network;Chat;
StartupWMClass=$STARTUP_WM_CLASS
EOF

cat > "$APP_DIR/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

rm -rf "$APP_DIR"
rm -f "$BIN_DIR/$APP_NAME"
rm -f "$DESKTOP_DIR/$APP_NAME.desktop"
rm -f "$ICON_DIR/${APP_NAME}.png"

echo "$DISPLAY_NAME has been removed from $PREFIX."
EOF
chmod 755 "$APP_DIR/uninstall.sh"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "$DISPLAY_NAME installed successfully."
echo "Binary: $BIN_DIR/$APP_NAME"
echo "Desktop entry: $DESKTOP_DIR/$APP_NAME.desktop"
echo "Uninstall: $APP_DIR/uninstall.sh"
echo
echo "ShareViaLAN uses UDP 9001 for discovery and TCP 9002 for messages."
echo "If your firewall blocks peers, open only those ports instead of disabling the firewall:"
echo "  firewalld: sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp"
echo "  ufw:       sudo ufw allow 9001/udp && sudo ufw allow 9002/tcp"
exit 0

__ARCHIVE_BELOW__
