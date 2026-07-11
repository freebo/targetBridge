#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="${SCRIPT_DIR}/TargetBridge.app"
DEST_APP="/Applications/TargetBridge.app"
NEXT_APP="/Applications/TargetBridge.next.$$.app"
BUNDLE_ID="com.targetbridge.sender"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "TargetBridge.app was not found beside this installer." >&2
  exit 1
fi

run_privileged() {
  if [[ -w /Applications ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "Verifying packaged application..."
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

# Private, ad-hoc signed builds downloaded from GitHub are quarantined by the
# browser. Remove quarantine only from this verified TargetBridge bundle.
xattr -dr com.apple.quarantine "$SOURCE_APP" 2>/dev/null || true

run_privileged rm -rf "$NEXT_APP"
run_privileged ditto "$SOURCE_APP" "$NEXT_APP"
run_privileged rm -rf "$DEST_APP"
run_privileged mv "$NEXT_APP" "$DEST_APP"

codesign --verify --deep --strict --verbose=2 "$DEST_APP"

echo
echo "TargetBridge installed at: $DEST_APP"
if pgrep -f '^/Applications/TargetBridge.app/Contents/MacOS/TargetBridge$' >/dev/null 2>&1; then
  echo "TargetBridge is currently running. Quit and reopen it manually to use this build."
else
  echo "TargetBridge was not launched. Open it manually when ready."
fi
echo
echo "On first launch, allow $BUNDLE_ID in Privacy & Security for:"
echo "  - Screen Recording"
echo "  - Accessibility"
echo "  - Input Monitoring"
