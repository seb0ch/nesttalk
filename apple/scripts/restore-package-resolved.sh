#!/usr/bin/env bash
# Restore the committed Package.resolved sidecar into the location
# Xcode looks for it before resolving SPM dependencies.
#
# xcodegen-generated `.xcodeproj` is gitignored, but `Package.resolved`
# lives inside it under `xcshareddata/`. We keep a sidecar at
# `apple/Package.resolved.checked-in` and this script copies it into the
# generated project path so reproducible-build dependency pins are honored
# in CI and on fresh clones.
#
# Run AFTER `xcodegen generate` and BEFORE `xcodebuild` for correct
# resolution behavior.

set -euo pipefail

cd "$(dirname "$0")/.."

SIDECAR="Package.resolved.checked-in"
DEST="NestTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"

if [[ ! -f "$SIDECAR" ]]; then
  echo "[restore-package-resolved] no sidecar at $SIDECAR — skip" >&2
  exit 0
fi

if [[ ! -d "NestTalk.xcodeproj" ]]; then
  echo "[restore-package-resolved] no NestTalk.xcodeproj — run xcodegen generate first" >&2
  exit 0
fi

mkdir -p "$DEST"
cp "$SIDECAR" "$DEST/Package.resolved"
echo "[restore-package-resolved] copied $SIDECAR → $DEST/Package.resolved"
