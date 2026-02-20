#!/bin/bash
# Install interbase.sh to ~/.intermod/interbase/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/lib/VERSION" 2>/dev/null || echo "1.0.0")
TARGET_DIR="${HOME}/.intermod/interbase"

mkdir -p "$TARGET_DIR"
# Atomic install: write temp, then mv (prevents partial reads by concurrent hooks)
cp "$SCRIPT_DIR/lib/interbase.sh" "$TARGET_DIR/interbase.sh.tmp.$$"
chmod 644 "$TARGET_DIR/interbase.sh.tmp.$$"
mv -f "$TARGET_DIR/interbase.sh.tmp.$$" "$TARGET_DIR/interbase.sh"
echo "$VERSION" > "$TARGET_DIR/VERSION.tmp.$$"
chmod 644 "$TARGET_DIR/VERSION.tmp.$$"
mv -f "$TARGET_DIR/VERSION.tmp.$$" "$TARGET_DIR/VERSION"

echo "Installed interbase.sh v${VERSION} to ${TARGET_DIR}/"
