#!/bin/zsh
# Regenerates the README screenshots in docs/media/ using the DEBUG-only demo mode.
#
# The app captures its own windows, so it needs the Screen Recording permission, and the
# build must be signed with the same team as the copy that was granted that permission.
# Each scene briefly shows a window on screen.
#
# Usage: scripts/generate-screenshots.sh [scene ...]
# Scenes: hero editor video-editor quick-access history settings pin (default: all)
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="${TMPDIR:-/tmp}/sbshot-demo-dd"
OUTPUT="$HOME/Library/Containers/com.burgos.sb-shot/Data/tmp/sb-shot-demo-output"
SCENES=("$@")
(( ${#SCENES} )) || SCENES=(hero editor video-editor quick-access history settings pin)

xcodebuild -project "$ROOT/sb-shot.xcodeproj" -scheme SbShot -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" build -quiet
APP="$DERIVED/Build/Products/Debug/SbShot.app"

for scene in $SCENES; do
  echo "Capturing $scene…"
  # Launch through LaunchServices so the app, not the terminal, needs the permission.
  open -n -W "$APP" --args -SbShotDemo "$scene" -AppleLanguages '(en)' -AppleLocale en_US &
  opener=$!
  for _ in {1..120}; do
    kill -0 $opener 2>/dev/null || break
    sleep 1
  done
  # Stop only the instance launched from this build if it is still running.
  pkill -f "$APP/Contents/MacOS/SbShot" 2>/dev/null || true
  kill $opener 2>/dev/null || true
  cp "$OUTPUT/$scene.png" "$ROOT/docs/media/$scene.png"
done

echo "Done: $ROOT/docs/media"
