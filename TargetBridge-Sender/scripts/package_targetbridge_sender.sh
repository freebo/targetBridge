#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SENDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SENDER_ROOT/.." && pwd)"
OUTPUT_ROOT="${1:-${REPO_ROOT}/build/distribution}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/targetbridge-sender-package.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

VERSION="$(awk '/MARKETING_VERSION:/ { gsub(/[" ]/, "", $2); print $2; exit }' "$SENDER_ROOT/project.yml")"
if [[ -z "$VERSION" ]]; then
  echo "Unable to determine Sender version from project.yml." >&2
  exit 1
fi

SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BUILD_HOST_ARCH="$(uname -m)"
STAGED_SENDER="$STAGING_ROOT/TargetBridge-Sender"
STAGED_SHARED="$STAGING_ROOT/TargetBridge-Shared"
DERIVED_DATA="$STAGING_ROOT/DerivedData"
PRODUCT_APP="$DERIVED_DATA/Build/Products/Release/TargetBridge.app"
PACKAGE_NAME="TargetBridge-Sender-${VERSION}-universal"
PACKAGE_DIR="$STAGING_ROOT/$PACKAGE_NAME"
ZIP_PATH="$OUTPUT_ROOT/${PACKAGE_NAME}.zip"
MANIFEST_PATH="$OUTPUT_ROOT/${PACKAGE_NAME}.json"

mkdir -p "$STAGED_SENDER" "$STAGED_SHARED" "$OUTPUT_ROOT"
rsync -a --exclude .build "$SENDER_ROOT/" "$STAGED_SENDER/"
rsync -a "$REPO_ROOT/TargetBridge-Shared/" "$STAGED_SHARED/"

echo "Building TargetBridge Sender $VERSION for arm64 and x86_64..."
xcodebuild \
  -project "$STAGED_SENDER/TargetBridge.xcodeproj" \
  -scheme TBDisplaySender \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "$PRODUCT_APP" ]]; then
  echo "Sender build did not produce $PRODUCT_APP" >&2
  exit 1
fi

BUILD_NUMBER="$(awk -F '"' '/buildNumber/ { print $2; exit }' "$STAGED_SENDER/TBDisplaySender/TBDisplaySenderBuildInfo.swift")"
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "Unable to read generated Sender build number." >&2
  exit 1
fi

mkdir -p "$PACKAGE_DIR"
ditto "$PRODUCT_APP" "$PACKAGE_DIR/TargetBridge.app"
cp "$SCRIPT_DIR/install_packaged_sender.sh" "$PACKAGE_DIR/install.sh"
chmod +x "$PACKAGE_DIR/install.sh"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$PACKAGE_DIR/TargetBridge.app"
  SIGNING_MODE="ad-hoc"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$PACKAGE_DIR/TargetBridge.app"
  SIGNING_MODE="Developer ID"
fi

EXECUTABLE="$PACKAGE_DIR/TargetBridge.app/Contents/MacOS/TargetBridge"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* ]]; then
  echo "Expected a universal executable, found: $ARCHITECTURES" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$PACKAGE_DIR/TargetBridge.app"

cat > "$PACKAGE_DIR/README.txt" <<EOF
TargetBridge Sender $VERSION (build $BUILD_NUMBER)

This package contains the Sender only. It is a universal macOS application for
Apple Silicon and Intel Macs and does not require Git, Xcode, or Homebrew on the
destination Mac.

Install:
  1. Open Terminal in this folder.
  2. Run: ./install.sh
  3. Open TargetBridge manually from /Applications.
  4. Grant Screen Recording, Accessibility, and Input Monitoring permissions.

Signing: $SIGNING_MODE
Source commit: $SOURCE_COMMIT
EOF

cat > "$PACKAGE_DIR/manifest.json" <<EOF
{
  "product": "TargetBridge Sender",
  "version": "$VERSION",
  "build_number": "$BUILD_NUMBER",
  "bundle_identifier": "com.targetbridge.sender",
  "architectures": ["arm64", "x86_64"],
  "minimum_macos": "14.0",
  "signing": "$SIGNING_MODE",
  "source_commit": "$SOURCE_COMMIT",
  "build_host_architecture": "$BUILD_HOST_ARCH"
}
EOF

rm -f "$ZIP_PATH" "$MANIFEST_PATH"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ZIP_PATH"
cp "$PACKAGE_DIR/manifest.json" "$MANIFEST_PATH"

ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')"
ARCHIVE_SIZE="$(stat -f '%z' "$ZIP_PATH")"

cat > "$MANIFEST_PATH" <<EOF
{
  "product": "TargetBridge Sender",
  "version": "$VERSION",
  "build_number": "$BUILD_NUMBER",
  "bundle_identifier": "com.targetbridge.sender",
  "architectures": ["arm64", "x86_64"],
  "minimum_macos": "14.0",
  "signing": "$SIGNING_MODE",
  "source_commit": "$SOURCE_COMMIT",
  "archive": "$(basename "$ZIP_PATH")",
  "archive_size": $ARCHIVE_SIZE,
  "sha256": "$ZIP_SHA256"
}
EOF

echo "Sender package: $ZIP_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "Build: $VERSION ($BUILD_NUMBER)"
echo "Architectures: $ARCHITECTURES"
echo "SHA-256: $ZIP_SHA256"
