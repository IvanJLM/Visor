# Changelog

## 1.0.0 — 2026-10-24

First release. A native Swift/AppKit image viewer written from scratch, using
qView 7.1 as the reference for behaviour (no qView code).

- Opens every format ImageIO decodes: JPEG, HEIC/HEIF, PNG, GIF, WebP, AVIF,
  TIFF, BMP, JPEG XL, camera RAW and more.
- Arrow keys walk the folder in Finder order; Home/End and ⌘↑/⌘↓ jump to the
  first or last image. The next image is decoded ahead, so most steps are instant.
- Pinch, ⌘+/⌘−, mouse wheel and double-click zoom; drag to pan; actual pixels
  (⌘0) and zoom to fit (⌘9). Zoomed-in pixels stay crisp.
- Rotate (⌘L/⌘R) and flip, view only. EXIF orientation is respected.
- Animated GIF, APNG, WebP and HEICS.
- HDR photos (gain maps, PQ/HLG) shown in HDR on HDR displays.
- Copy, Move to Trash (⌘⌫), Show in Finder, Open in Preview, full screen.
- Offers once to become the default image viewer (macOS asks you to confirm).
- Memory: a single window stays near 17 MB; 25 open windows stay under 45 MB.
