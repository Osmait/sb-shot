# Media shot list

Images and animations used by the main [README](../../README.md). Keep the file names exactly as listed: the README links to them.

## Regenerating the still images

All the PNGs (`hero`, `editor`, `video-editor`, `quick-access`, `history`, `settings`, `pin`) are produced by a DEBUG-only demo mode (`sb-shot/App/DemoMode.swift`) that opens each window with synthetic content and captures it with ScreenCaptureKit:

```bash
scripts/generate-screenshots.sh            # all scenes
scripts/generate-screenshots.sh editor pin # only some
```

The app needs the Screen Recording permission, and each scene briefly shows a window on screen. The demo uses isolated settings, a temporary history and a synthetic wallpaper, so nothing from your machine ends up in the images.

`demo.gif` and `demo.mp4` (annotating a capture, adding a background, then trimming a recording and giving it a background) are rendered the same way, frame by frame, and encoded with ffmpeg:

```bash
scripts/generate-demo-gif.sh        # 1200 px wide
scripts/generate-demo-gif.sh 960    # smaller
```

The two capture and recording GIFs below still have to be recorded by hand.

## General guidelines

- **Resolution:** capture on a Retina display (2x). Keep still images under ~1 MB (use `pngquant` or `oxipng` if needed) and GIFs under ~5 MB.
- **App language:** English (System Settings › General › Language & Region › Applications, or the scheme's App Language option).
- **Appearance:** light mode unless noted; one consistent accent color across all shots.
- **Desktop:** a neutral wallpaper (a macOS default such as Sequoia or a plain gradient), desktop icons hidden, Dock auto-hidden, a clean menu bar.
- **Content:** no personal information: no real names, emails, notifications, browser tabs, file paths with your user name or private documents. Use sample content (a public website, lorem ipsum, a demo project).
- **Window shots:** include the macOS window shadow. With sb-shot itself: ⇧⌘7 (Capture Window) with **Include shadow in window captures** turned on. Or with the system tool:

```bash
# List the ids of sb-shot's on-screen windows (the terminal needs the Screen Recording permission to see titles)
cat > /tmp/sbshot-windows.swift <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerName as String] as? String == "SbShot" {
    print(window[kCGWindowNumber as String] ?? "", window[kCGWindowName as String] ?? "")
}
SWIFT
swift /tmp/sbshot-windows.swift

screencapture -l <windowid> -x editor.png
```

`screencapture -l <windowid> file.png` captures a single window (with shadow by default), `-o` removes the shadow, `-x` silences the sound.

## App icon

`icon.png` (256 × 256) is a copy of `sb-shot/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`, drawn by `swift scripts/make-icon.swift`. Copy it again after regenerating the icon.

## Shots

| File | What it shows | Suggested size |
|---|---|---|
| `hero.png` | The annotation editor with a polished capture: a browser or app window on the **wallpaper background** with some blur, rounded corners and shadow; a couple of annotations (arrow, numbered counters, a highlighted area). Optionally a Quick Access thumbnail in the corner. This is the first image people see. | 2400 × 1500 px (1200 × 750 pt @2x), window shadow |
| `editor.png` | The annotation editor window with the toolbar visible, several tools used (arrow, rectangle, text with background, counter, pixelate on a fake email address, spotlight) and the inspector showing the background options. | Window @2x with shadow |
| `video-editor.png` | The video editor with a recording loaded, the trim handles moved in from both ends, the export panel showing MP4/GIF options, and the background enabled (gradient or wallpaper). | Window @2x with shadow |
| `quick-access.png` | A corner of the screen with two or three stacked Quick Access thumbnails, the top one hovered so Copy / Save / Annotate / Pin are visible. Crop to the bottom-right corner area. | ~1200 × 900 px @2x crop |
| `history.png` | The history window with a grid of mixed items (screenshots, a video, a GIF) and the hover actions visible on one item. | Window @2x with shadow |
| `settings.png` | The Settings window, **General** tab (or **Shortcuts** tab showing the default shortcuts). | Window @2x with shadow |
| `pin.png` | A pinned capture floating over another app (for example a code snippet pinned over an editor), ideally with the context menu open showing Opacity. | ~1600 × 1000 px @2x crop |
| `demo-capture.gif` | ⇧⌘2 → hover over windows to show the click target → drag an area with the magnifier visible → Quick Access appears → drag the thumbnail into another app. 8–12 seconds. | 1200 px wide max, 15–20 fps, loops |
| `demo-recording.gif` | ⇧⌘9 → select an area → countdown → do something with visible clicks (click highlighting on) → stop from the control bar → open the video editor → trim → enable the wallpaper background → export as GIF. 12–20 seconds. | 1200 px wide max, 12–15 fps, loops |

## Recording the GIFs

Record the demos as video first (sb-shot itself in MP4, or QuickTime Player), then convert:

```bash
# Option 1: gifski (best quality/size ratio)
brew install ffmpeg gifski
ffmpeg -i demo.mp4 -vf "fps=15,scale=1200:-1:flags=lanczos" frames/%04d.png
gifski --fps 15 --width 1200 --quality 85 -o demo-capture.gif frames/*.png

# Option 2: ffmpeg only (palette-based)
ffmpeg -i demo.mp4 -vf "fps=15,scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" -loop 0 demo-recording.gif
```

Tips:

- Trim dead time at the start and end (`ffmpeg -ss 00:00:01 -to 00:00:12 -i in.mp4 -c copy out.mp4`).
- Move the cursor slowly and deliberately; pause briefly on each important state.
- Prefer a smaller capture area over downscaling a full 5K screen, so text stays readable.
- If a GIF is still too large, lower the fps to 12 or the width to 960 px before lowering quality.
