# Visor

A minimal, native image viewer for Apple Silicon Macs.

Visor does one thing: it opens images, fast, and gets out of the way. It is
written from scratch in Swift and AppKit, with no third-party code, using
[qView](https://github.com/jurplel/qView) 7.1 as the reference for how a
minimal viewer should behave. qView is built on Qt; Visor uses only what
macOS already ships: ImageIO to decode, Core Animation to draw, AppKit for
windows and menus.

## Why

Same 12 MP photo open, measured on an M-series Mac with macOS 26:

| | Visor 1.0 | Preview | qView 7.1 |
|---|---|---|---|
| Memory (Activity Monitor) | 17 MB | 88 MB | 193 MB |
| CPU while idle | 0.0 % | 0.5 % | 0.0 % |
| Wake-ups while idle | 0 | 1 | 2 |
| Threads | 3 | 6 | 14 |
| App size | 0.9 MB | — | 117 MB |

Visor quits when its last window closes, so it uses no memory at all when
you are not looking at an image.

## What it does

- **Opens everything macOS can decode**: JPEG, HEIC/HEIF, PNG, GIF, WebP,
  AVIF, TIFF, BMP, JPEG XL, camera RAW, PSD and more.
- **Browse the folder** with the arrow keys, in Finder's order. The next
  image is decoded ahead of time, so moving on is instant.
- **Zoom** with a pinch, ⌘+ / ⌘−, the mouse wheel or a double-click. ⌘0
  shows actual pixels (one image pixel per screen pixel), ⌘9 fits the window.
  Drag to pan. Past 300 % the pixels are shown as sharp squares.
- **Rotate and flip** the view (⌘L, ⌘R). EXIF orientation is always respected.
- **Animated GIF, APNG, WebP and HEICS**, one frame in memory at a time.
- **HDR photos** (iPhone gain maps, PQ and HLG) in real HDR on HDR displays.
- **Copy** (⌘C), **Move to Trash** (⌘⌫), **Show in Finder** (⇧⌘R),
  **Open in Preview** (⇧⌘P), **full screen** (⌃⌘F, Esc to leave).
- Drop an image on a window to open it there.

There are no preferences, no toolbar, no slideshow and no auto-updates.

## Shortcuts

| Key | Action |
|---|---|
| ← → | Previous / next image |
| ⌘↑ ⌘↓ (Home, End) | First / last image |
| ⌘0 / ⌘9 | Actual pixels / zoom to fit |
| ⌘+ / ⌘− | Zoom in / out |
| ⌘L / ⌘R | Rotate left / right |
| ⌘C | Copy the image |
| ⌘⌫ | Move to Trash and show the next image |
| ⇧⌘R / ⇧⌘P | Show in Finder / open in Preview |
| ⌃⌘F, Esc | Enter / leave full screen |

## Image quality

Visor never shows a lower-quality version of your image than your screen can
display:

- Each image is decoded at exactly the size it is shown, pixel for pixel, by
  the system codecs. Zoom in and the full-resolution pixels are decoded.
- Every embedded color profile is honored (sRGB, Display P3, Adobe RGB,
  camera profiles); CMYK becomes wide-gamut RGB.
- 16-bit PNG and TIFF keep their full bit depth.
- 8-bit images are color matched to your display once, off the main thread,
  with the same ColorSync conversion macOS would apply when drawing them.

## How it stays light

- One decode queue for all windows: decoding never runs in parallel, so peak
  memory stays at one image.
- At most two bitmaps per window: the one on screen and the next one. Only the
  window in front prefetches.
- Bitmaps are prepared in the display's own color space, so Core Animation
  shows them as they are instead of keeping a converted copy of each one.
- Menus are built in code (no nib to load), there are no timers and nothing
  runs while you look at an image.

Stress test on 75 images (12 to 108 MP, HEIC, 16-bit PNG, GIF, HDR…):

| Test | Result |
|---|---|
| Next image, 3 passes over the folder | median 2.2 ms, memory flat at 33-38 MB |
| Holding the arrow key through 300 images | 43 MB |
| Zoom, rotate and flip on 15 images | peak 50 MB |
| 25 windows open | 43 MB |
| Back to 1 window | 38 MB |

## Install

Requirements: an Apple Silicon Mac with macOS 15 or later, Xcode 26 or later,
and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
./scripts/install.sh
```

The script builds a Release copy, installs it in `/Applications` and asks
macOS to make Visor the default app for images. macOS asks you to confirm
each change in its own dialog; Visor first asks for all images at once and
only then for any common format still opening elsewhere, one at a time. To skip that step, run `./scripts/install.sh --no-default`.

To install on another Mac, run `./scripts/package.sh`, copy
`dist/Visor-<version>.zip` over, unzip it into `/Applications` and open Visor
once: it offers to become the default viewer.

## Development

```bash
./scripts/test.sh                 # unit tests (Debug build)
./scripts/bump-version.sh minor   # or patch / major, then fill in CHANGELOG.md
swiftc -O scripts/generate-test-images.swift -o /tmp/gen && /tmp/gen /tmp/visor-images
./scripts/benchmark.sh /tmp/visor-images
```

The benchmark builds a separate copy of Visor with the stress test compiled
in (`-D VISOR_BENCH`); the installed app never contains it.

## License

[MIT](LICENSE). Use it for anything you like.
