#!/usr/bin/env bash
# The whole gate in one command, for a Mac. Nothing else runs it: the
# workflow file needs a macOS runner and none is set up.
#
#   scripts/check-all.sh            build, unit tests, core checks and the
#                                   scratch-only installer, upgrade and backup
#                                   tests
#   scripts/check-all.sh --release  the above, then package a release folder
#                                   and run the release checks against it
#
# Everything here stays in scratch folders. It never touches an installed
# copy of the app, a real login item or the real archive, and never reads the
# clipboard.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RELEASE=false
if [ "${1:-}" = "--release" ]; then
  RELEASE=true
elif [ -n "${1:-}" ]; then
  echo "usage: $0 [--release]" >&2
  exit 2
fi

# A store variable left in the shell would send these runs somewhere real.
for variable in $(env | /usr/bin/grep -o '^CLIPBOARD_ARCHIVE_[A-Z_]*' || true); do
  unset "$variable"
done

step() { echo; echo "== $*"; }

step "build"
/usr/bin/xcrun swift build --build-tests
step "unit tests"
/usr/bin/xcrun swift test --skip-build
step "core checks"
SCRATCH="$(/usr/bin/mktemp -d /tmp/clipboard-archive-check-all.XXXXXX)"
trap '/bin/rm -rf "$SCRATCH"' EXIT
CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$SCRATCH/support" \
CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$SCRATCH/archive" \
CLIPBOARD_ARCHIVE_INDEX_PATH="$SCRATCH/index/search.sqlite" \
CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST="$SCRATCH/agent.plist" \
  /usr/bin/xcrun swift run --quiet clipboard-archive-checks
step "install locations"
./scripts/test-install-locations.sh
step "an update keeps history, settings and data location"
./scripts/test-upgrade-keeps-data.sh
step "backup round trip"
./scripts/backup-roundtrip-check.sh

if [ "$RELEASE" = true ]; then
  # shellcheck source=lib/release-identity.sh
  . scripts/lib/release-identity.sh
  read -r version build <<<"$(release_identity_newest CHANGELOG.md)"
  folder="releases/ClipboardArchive-${version}-macos-$(/usr/bin/uname -m)"
  step "package $version build $build"
  ./scripts/package-release.sh
  step "validate the release folder"
  ./scripts/validate-release.sh "$folder"
  step "failed-update rollback"
  ./scripts/test-install-rollback.sh "$folder"
  step "the upgrade test against the packaged command-line tool"
  CLIPBOARD_ARCHIVE_TEST_CLI="$ROOT/$folder/bin/clipboard-archive" ./scripts/test-upgrade-keeps-data.sh
fi

echo
echo "all checks passed"
