#!/bin/zsh
# Renders the animated demo (annotating a capture, then trimming a recording) to docs/media/demo.gif and demo.mp4,
# using the DEBUG-only demo mode. Needs the Screen Recording permission (see generate-screenshots.sh) and ffmpeg.
#
# Usage: scripts/generate-demo-gif.sh [width]   (default width: 1200 px)
set -euo pipefail

ROOT="${0:A:h:h}"
WIDTH="${1:-1200}"
DERIVED="${TMPDIR:-/tmp}/sbshot-demo-dd"
FRAMES="$HOME/Library/Containers/com.burgos.sb-shot/Data/tmp/sb-shot-demo-output/animation"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg"; exit 1; }

xcodebuild -project "$ROOT/sb-shot.xcodeproj" -scheme SbShot -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" build -quiet
APP="$DERIVED/Build/Products/Debug/SbShot.app"

echo "Recording frames…"
open -n -W "$APP" --args -SbShotDemo animation -AppleLanguages '(en)' -AppleLocale en_US &
opener=$!
for _ in {1..260}; do
  kill -0 $opener 2>/dev/null || break
  sleep 1
done
pkill -f "$APP/Contents/MacOS/SbShot" 2>/dev/null || true
kill $opener 2>/dev/null || true
[[ -f "$FRAMES/frames.txt" ]] || { echo "No frames were written"; exit 1; }

cd "$FRAMES"
echo "Encoding GIF…"
ffmpeg -loglevel error -y -f concat -safe 0 -i frames.txt \
  -vf "fps=20,scale=${WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=192[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 "$ROOT/docs/media/demo.gif"

echo "Encoding MP4…"
ffmpeg -loglevel error -y -f concat -safe 0 -i frames.txt \
  -vf "fps=30,scale=${WIDTH}:-2:flags=lanczos,format=yuv420p" -c:v libx264 -crf 20 -preset slow -movflags +faststart \
  "$ROOT/docs/media/demo.mp4"

ls -lh "$ROOT/docs/media/demo.gif" "$ROOT/docs/media/demo.mp4"
