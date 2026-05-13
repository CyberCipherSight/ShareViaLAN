#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/ShareViaLAN-linux-installer-1.0.0.sh"

if [[ ! -x "$INSTALLER" ]]; then
  chmod +x "$INSTALLER"
fi

exec "$INSTALLER" "$@"
