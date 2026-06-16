#!/usr/bin/env bash
# Render NestTalk's AppIcon and LoginHero asset variants from the canonical
# source images under apple/branding/. Idempotent — re-running rebuilds every
# variant from the source.
#
# Source: apple/branding/icon.png       (1024x1024 RGB, app icon)
#         apple/branding/icon-hero.png  (800x800 RGBA, welcome-screen hero)
#
# Outputs:
#   apple/NestTalk/Shared/Resources/Assets.xcassets/AppIcon.appiconset/
#     AppIcon-ios.png            (1024)
#     AppIcon-mac-{16,32,128,256,512}.png    @1x and @2x
#   apple/NestTalk/Shared/Resources/Assets.xcassets/LoginHero.imageset/
#     LoginHero.png  (360)
#     LoginHero@2x.png  (720)
#     LoginHero@3x.png  (1080)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_ICON="$ROOT/apple/branding/icon.png"
SRC_HERO="$ROOT/apple/branding/icon-hero.png"
APPICON_DIR="$ROOT/apple/NestTalk/Shared/Resources/Assets.xcassets/AppIcon.appiconset"
HERO_DIR="$ROOT/apple/NestTalk/Shared/Resources/Assets.xcassets/LoginHero.imageset"

[[ -f "$SRC_ICON" ]] || { echo "missing $SRC_ICON" >&2; exit 1; }
[[ -f "$SRC_HERO" ]] || { echo "missing $SRC_HERO" >&2; exit 1; }
mkdir -p "$APPICON_DIR" "$HERO_DIR"

# AppIcon — render every required size from the 1024 source.
render() { sips -s format png -Z "$2" "$SRC_ICON" --out "$APPICON_DIR/$1" >/dev/null; }
render AppIcon-ios.png       1024
render AppIcon-mac-16.png      16
render AppIcon-mac-16@2x.png   32
render AppIcon-mac-32.png      32
render AppIcon-mac-32@2x.png   64
render AppIcon-mac-128.png    128
render AppIcon-mac-128@2x.png 256
render AppIcon-mac-256.png    256
render AppIcon-mac-256@2x.png 512
render AppIcon-mac-512.png    512
render AppIcon-mac-512@2x.png 1024

# LoginHero — render from the cropped hero source.
sips -s format png -Z 360  "$SRC_HERO" --out "$HERO_DIR/LoginHero.png"     >/dev/null
sips -s format png -Z 720  "$SRC_HERO" --out "$HERO_DIR/LoginHero@2x.png"  >/dev/null
sips -s format png -Z 1080 "$SRC_HERO" --out "$HERO_DIR/LoginHero@3x.png"  >/dev/null

echo "[icons] AppIcon + LoginHero rendered."
