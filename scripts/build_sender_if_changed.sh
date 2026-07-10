#!/usr/bin/env bash
set -euo pipefail

PROJECT_REL="TargetBridge-Sender/TargetBridge.xcodeproj"
SCHEME="TBDisplaySender"
CONFIGURATION="Release"
RELEASE_TAG="local-builds"
RELEASE_TITLE="Local builds"
MANIFEST_REL="build-artifacts/build-manifest.json"
REPO_SLUG="freebo/targetBridge"

force=0
allow_dirty=0
no_upload=0
mark_receiver_built=0

usage() {
  cat <<'EOF'
Usage: scripts/build_sender_if_changed.sh [options]

Build and optionally upload the TargetBridge Sender Release app when Sender
source has changed.

Options:
  --force                 Rebuild Sender even if the source hash is unchanged.
  --allow-dirty           Allow uncommitted source changes in tracked source paths.
  --no-upload             Build/package only; do not create or upload GitHub release assets.
  --mark-receiver-built   Record the current Receiver source hash/commit in the manifest
                          without building Sender. Use after Receiver was built separately.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      ;;
    --allow-dirty)
      allow_dirty=1
      ;;
    --no-upload)
      no_upload=1
      ;;
    --mark-receiver-built)
      mark_receiver_built=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

manifest_get() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  /usr/bin/plutil -extract "$key" raw -o - "$file" 2>/dev/null || true
}

source_hash() {
  local repo_root="$1"
  shift

  (
    cd "$repo_root"
    git ls-files -z -- "$@" \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' path; do
          [[ -f "$path" ]] || continue
          printf '%s  %s\0' "$(git hash-object -- "$path")" "$path"
        done \
      | git hash-object --stdin
  )
}

has_source_changes() {
  local repo_root="$1"
  shift

  (
    cd "$repo_root"
    [[ -z "$(git status --porcelain -- "$@")" ]]
  )
}

write_manifest() {
  local file="$1"
  local sender_hash="$2"
  local receiver_hash="$3"
  local sender_commit="$4"
  local receiver_commit="$5"
  local timestamp="$6"
  local branch="$7"
  local architecture="$8"
  local macos_version="$9"
  local xcode_version="${10}"
  local product_filename="${11}"
  local release_tag="${12}"
  local release_asset_name="${13}"

  cat > "$file" <<EOF
{
  "sender_source_hash": "$(json_escape "$sender_hash")",
  "receiver_source_hash": "$(json_escape "$receiver_hash")",
  "sender_commit": "$(json_escape "$sender_commit")",
  "receiver_commit": "$(json_escape "$receiver_commit")",
  "build_timestamp_utc": "$(json_escape "$timestamp")",
  "branch": "$(json_escape "$branch")",
  "architecture": "$(json_escape "$architecture")",
  "macos_version": "$(json_escape "$macos_version")",
  "xcode_version": "$(json_escape "$xcode_version")",
  "product_filename": "$(json_escape "$product_filename")",
  "release_tag": "$(json_escape "$release_tag")",
  "release_asset_name": "$(json_escape "$release_asset_name")"
}
EOF
}

print_install_command() {
  local asset_name="$1"

  cat <<EOF
Copy-and-paste install command for another Sender Mac:

tmpdir="\$(mktemp -d)" && \\
mkdir -p "\$tmpdir/unpacked" && \\
gh release download "$RELEASE_TAG" \\
  --repo "$REPO_SLUG" \\
  --pattern "$asset_name" \\
  --dir "\$tmpdir" && \\
{ pkill -x "TargetBridge" 2>/dev/null || true; } && \\
sudo rm -rf "/Applications/TargetBridge.app" && \\
ditto -x -k "\$tmpdir/$asset_name" "\$tmpdir/unpacked" && \\
sudo ditto "\$tmpdir/unpacked/TargetBridge.app" "/Applications/TargetBridge.app" && \\
sudo xattr -dr com.apple.quarantine "/Applications/TargetBridge.app" && \\
open "/Applications/TargetBridge.app" && \\
rm -rf "\$tmpdir"

After replacing the app, check these macOS permissions if Sender behavior changes:
- Screen & System Audio Recording
- Accessibility
- Input Monitoring
EOF
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a Git repository."
cd "$repo_root"

[[ -d "TargetBridge-Sender" && -d "TargetBridge-Receiver" && -d "TargetBridge-Shared" ]] \
  || die "Not inside the TargetBridge repository: $repo_root"
[[ -d "$PROJECT_REL" ]] || die "Missing Sender Xcode project: $PROJECT_REL"

branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  branch="DETACHED"
fi
commit_sha="$(git rev-parse HEAD)"
architecture="$(uname -m)"
macos_version="$(sw_vers -productVersion)"
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
manifest_path="$repo_root/$MANIFEST_REL"
artifacts_dir="$repo_root/build-artifacts"
asset_name="TargetBridge-Sender-${architecture}.zip"
asset_path="$artifacts_dir/$asset_name"

sender_paths=(
  "TargetBridge-Sender"
  "TargetBridge-Shared"
)
receiver_paths=(
  "TargetBridge-Receiver"
  "TargetBridge-Shared"
)

echo "Repository: $repo_root"
echo "Branch: $branch"
echo "Commit: $commit_sha"

if [[ "$allow_dirty" -ne 1 ]]; then
  has_source_changes "$repo_root" "${sender_paths[@]}" "${receiver_paths[@]}" \
    || die "Uncommitted source changes found. Commit/stash them or rerun with --allow-dirty."
fi

mkdir -p "$artifacts_dir"

sender_hash="$(source_hash "$repo_root" "${sender_paths[@]}")"
receiver_hash="$(source_hash "$repo_root" "${receiver_paths[@]}")"
last_sender_hash="$(manifest_get "sender_source_hash" "$manifest_path")"
last_receiver_hash="$(manifest_get "receiver_source_hash" "$manifest_path")"
last_sender_commit="$(manifest_get "sender_commit" "$manifest_path")"
last_receiver_commit="$(manifest_get "receiver_commit" "$manifest_path")"
last_product_filename="$(manifest_get "product_filename" "$manifest_path")"
last_release_asset_name="$(manifest_get "release_asset_name" "$manifest_path")"
recorded_receiver_hash="${last_receiver_hash:-$receiver_hash}"
recorded_receiver_commit="${last_receiver_commit:-$commit_sha}"

receiver_needs_rebuild=0
if [[ -n "$last_receiver_hash" && "$receiver_hash" != "$last_receiver_hash" ]]; then
  receiver_needs_rebuild=1
fi

if [[ "$mark_receiver_built" -eq 1 ]]; then
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  product_filename="${last_product_filename:-TargetBridge.app}"
  release_asset_name="${last_release_asset_name:-$asset_name}"
  write_manifest \
    "$manifest_path" \
    "${last_sender_hash:-$sender_hash}" \
    "$receiver_hash" \
    "${last_sender_commit:-$commit_sha}" \
    "$commit_sha" \
    "$timestamp" \
    "$branch" \
    "$architecture" \
    "$macos_version" \
    "$xcode_version" \
    "$product_filename" \
    "$RELEASE_TAG" \
    "$release_asset_name"

  echo "Receiver build recorded in $MANIFEST_REL"
  echo "Receiver source hash: $receiver_hash"
  echo "Receiver commit: $commit_sha"
  exit 0
fi

built_sender=0
skipped_sender=0
product_filename="${last_product_filename:-TargetBridge.app}"

if [[ "$force" -ne 1 && -n "$last_sender_hash" && "$sender_hash" == "$last_sender_hash" && -f "$asset_path" ]]; then
  echo "Sender source unchanged; build skipped."
  skipped_sender=1
else
  echo "Building Sender with configuration: $CONFIGURATION"
  xcodebuild \
    -project "$PROJECT_REL" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    build

  build_settings="$(xcodebuild \
    -project "$PROJECT_REL" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings)"
  target_build_dir="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / {print $2; exit}')"
  full_product_name="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / {print $2; exit}')"

  [[ -n "$target_build_dir" ]] || die "Could not determine TARGET_BUILD_DIR from xcodebuild -showBuildSettings."
  [[ -n "$full_product_name" ]] || die "Could not determine FULL_PRODUCT_NAME from xcodebuild -showBuildSettings."

  built_app_path="$target_build_dir/$full_product_name"
  [[ -d "$built_app_path" ]] || die "Built app missing: $built_app_path"
  product_filename="$full_product_name"

  echo "Packaging $built_app_path"
  ditto -c -k --sequesterRsrc --keepParent \
    "$built_app_path" \
    "$asset_path"
  [[ -f "$asset_path" ]] || die "Packaged asset missing: $asset_path"
  built_sender=1
fi

if [[ "$skipped_sender" -eq 1 && ! -f "$asset_path" ]]; then
  die "Sender was skipped but packaged asset is missing: $asset_path"
fi

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_manifest \
  "$manifest_path" \
  "$sender_hash" \
  "$recorded_receiver_hash" \
  "$commit_sha" \
  "$recorded_receiver_commit" \
  "$timestamp" \
  "$branch" \
  "$architecture" \
  "$macos_version" \
  "$xcode_version" \
  "$product_filename" \
  "$RELEASE_TAG" \
  "$asset_name"

upload_status="not requested (--no-upload)"
if [[ "$no_upload" -eq 0 ]]; then
  gh auth status >/dev/null

  if ! gh release view "$RELEASE_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" \
      --repo "$REPO_SLUG" \
      --title "$RELEASE_TITLE" \
      --notes "Reusable prerelease for local TargetBridge Sender builds." \
      --prerelease
  fi

  gh release upload "$RELEASE_TAG" \
    "$asset_path" \
    "$manifest_path" \
    --repo "$REPO_SLUG" \
    --clobber
  upload_status="succeeded"
fi

if [[ "$receiver_needs_rebuild" -eq 1 ]]; then
  cat <<'EOF'

WARNING: Receiver source has changed since the last recorded Receiver build.
Rebuild and install TargetBridge Receiver on the iMac.
EOF
fi

cat <<EOF

Summary:
Sender built: $([[ "$built_sender" -eq 1 ]] && printf 'yes' || printf 'no')
Sender skipped: $([[ "$skipped_sender" -eq 1 ]] && printf 'yes' || printf 'no')
Build configuration: $CONFIGURATION
Sender source hash: $sender_hash
Receiver current source hash: $receiver_hash
Receiver recorded build hash: $recorded_receiver_hash
Receiver needs rebuilding: $([[ "$receiver_needs_rebuild" -eq 1 ]] && printf 'yes' || printf 'no')
Packaged asset path: $asset_path
Upload: $upload_status
Commit SHA used: $commit_sha
GitHub release tag: $RELEASE_TAG
Manifest: $manifest_path

EOF

if [[ "$no_upload" -eq 0 ]]; then
  print_install_command "$asset_name"
else
  echo "Install command omitted because --no-upload was used."
fi
