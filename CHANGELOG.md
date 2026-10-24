# Changelog

## 1.1.0 — 2026-10-24

- Zoom obeys on the first press: from "zoom to fit", Actual Size (⌘0), Zoom
  In/Out, the mouse wheel, a pinch and the double-click used to need two tries
  (the double-click never zoomed in).
- Rotate and flip are now done by the GPU: instant at any size (a 108 MP
  photo at actual pixels took a quarter of a second) and with no extra copy of
  the image in memory. 16-bit grayscale images can be rotated.
- Zooming to actual pixels needs a third less memory (two copies of the image
  while decoding instead of three: 843 MB instead of 1.26 GB for 108 MP).
- Sharp pixels past 300 % now follow the bitmap actually shown, so a photo at
  100 % is never drawn as squares.
- The next image is no longer decoded again when you switch back to Visor.
- Unit tests (`./scripts/test.sh`) and CI on GitHub Actions.

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
