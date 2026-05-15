#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-${CLIPBOARD_ARCHIVE_GITHUB_REPO:-ValyouHustlin/clipboard-archive-tool}}"
VERSION="${2:-${CLIPBOARD_ARCHIVE_VERSION:-latest}}"
ARCH="${CLIPBOARD_ARCHIVE_ARCH:-$(uname -m)}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-update.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Install or update Clipboard Archive from a GitHub Release.

Usage:
  ./scripts/install-latest-github-release.sh [OWNER/REPO] [latest|v0.1.0|0.1.0]

Environment:
  CLIPBOARD_ARCHIVE_GITHUB_REPO   OWNER/REPO default, defaults to ValyouHustlin/clipboard-archive-tool
  CLIPBOARD_ARCHIVE_VERSION       latest, v0.1.0, or 0.1.0
  CLIPBOARD_ARCHIVE_ARCH          Default: uname -m

Examples:
  ./scripts/install-latest-github-release.sh
  ./scripts/install-latest-github-release.sh ValyouHustlin/clipboard-archive-tool v0.1.0
USAGE
}

if [ -z "$REPO" ] || [ "$REPO" = "--help" ] || [ "$REPO" = "-h" ]; then
  usage
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for GitHub release updates" >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "ditto is required to unpack the release zip" >&2
  exit 1
fi

case "$VERSION" in
  latest)
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    ;;
  v*)
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
    ;;
  *)
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/v${VERSION}"
    ;;
esac

echo "repo: $REPO"
echo "version: $VERSION"
echo "arch: $ARCH"

release_json="$TMP_ROOT/release.json"
curl -fsSL "$API_URL" -o "$release_json"

asset_url="$(
  awk -v arch="$ARCH" '
    /"browser_download_url":/ && $0 ~ "ClipboardArchive-" && $0 ~ "-macos-" arch "\\.zip" {
      gsub(/[",]/, "", $2)
      print $2
      exit
    }
  ' "$release_json"
)"

if [ -z "$asset_url" ]; then
  echo "no matching ClipboardArchive macOS $ARCH zip asset found in release" >&2
  exit 1
fi

release_tag="$(
  awk '
    /"tag_name":/ {
      gsub(/[",]/, "", $2)
      print $2
      exit
    }
  ' "$release_json"
)"

zip_path="$TMP_ROOT/ClipboardArchive.zip"
unpack_dir="$TMP_ROOT/unpacked"
mkdir -p "$unpack_dir"

echo "download: $asset_url"
curl -fL "$asset_url" -o "$zip_path"
ditto -x -k "$zip_path" "$unpack_dir"

release_dir="$(
  find "$unpack_dir" -maxdepth 1 -type d -name 'ClipboardArchive-*-macos-*' | head -1
)"

if [ -z "$release_dir" ] || [ ! -d "$release_dir" ]; then
  echo "unpacked release folder not found" >&2
  exit 1
fi

if [ -f "$release_dir/SHA256SUMS" ]; then
  (
    cd "$release_dir"
    shasum -a 256 -c SHA256SUMS >/dev/null
  )
  echo "checksums: ok"
else
  echo "missing SHA256SUMS in release" >&2
  exit 1
fi

if [ ! -x "$release_dir/install.sh" ]; then
  echo "missing executable install.sh in release" >&2
  exit 1
fi

(
  cd "$release_dir"
  ./install.sh
)

if [ -n "$release_tag" ]; then
  echo "installed_version: $release_tag"
fi
echo "update complete"
echo "verify: ~/.local/bin/clipboard-archive health"
