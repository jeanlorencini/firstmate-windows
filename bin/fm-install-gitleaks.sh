#!/usr/bin/env bash
# fm-install-gitleaks.sh - install CI's pinned, verified gitleaks build.
#
# Downloads the official GitHub release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux x86_64/arm64, darwin x86_64/arm64.
# Pins come from gitleaks_8.30.1_checksums.txt on the official v8.30.1 release
# (https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1). An unsupported
# OS/arch fails without downloading.
#
# Usage:
#   fm-install-gitleaks.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint-secrets.sh" --required-version)"

die() {
  printf 'fm-install-gitleaks.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-gitleaks.sh <destination-directory>}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="gitleaks_${VERSION}_linux_x64.tar.gz"
    SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="gitleaks_${VERSION}_linux_arm64.tar.gz"
    SHA256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="gitleaks_${VERSION}_darwin_x64.tar.gz"
    SHA256=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="gitleaks_${VERSION}_darwin_arm64.tar.gz"
    SHA256=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    ;;
  *)
    die "unsupported platform $(uname -s)-$(uname -m); need linux or darwin on x86_64 or arm64"
    ;;
esac

URL="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-gitleaks.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$TMP/$ARCHIVE" || die "download failed: $URL"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the gitleaks archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP" gitleaks
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/gitleaks" "$DESTINATION/gitleaks"
"$DESTINATION/gitleaks" version
