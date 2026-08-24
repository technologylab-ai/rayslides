# Rayslides release notes

## Unreleased — four-topic roadmap completion

The software work for the current four-topic roadmap is implemented. This is
not yet a release declaration: physical-phone venue rehearsal and a real
projector pass remain open in
[`ROADMAP.md`](ROADMAP.md).

### First-class image and video authoring

- Image and Video are source-native Studio tools with matching insertion,
  filename-first Properties, separate Replace actions, drag-and-drop, safe
  deck-relative paths, Undo/Redo, reusable-definition ownership, and missing
  media repair boxes.
- Images support raster formats and the embedded NanoSVG vector subset. SVG
  `<text>` is intentionally unsupported; convert text to paths.
- Both media kinds share box sizing, Stretch/Fit/Fill, focal position, opacity,
  natural-size feedback, diagnostics, portable-show copying, screenshots, PDF,
  Presenter preview, and Showtime validation.
- Video adds authored poster time, scrubber, autoplay, loop, mute, volume,
  duration/audio feedback, and ffmpeg/ffprobe diagnostics. Passive outputs use
  the poster frame and never disturb audience playback.
- Live `cam=` items reuse the video texture pipeline on AVFoundation, V4L2,
  and DirectShow. They support authored capture size, stopped/export posters,
  the playback pill, rotation and the complete media transform stack, plus
  device-start notifications and Showtime findings.

On macOS, insertion and replacement offer a native file picker. Linux and
Windows keep the portable manual-path prompt; all platforms accept media file
drops. Video requires `ffmpeg` and `ffprobe` on `PATH`.

### Presenter Companion venue resilience

- Presenter pairing discovers and explains usable IPv4 interfaces, rotates the
  private capability when the advertised network changes, and keeps stale
  sessions unauthorized.
- The responsive offline client provides Notes, sequenced navigation, live
  rendered preview, Pointer, Draw, wake-lock/reconnect behavior, safe bounded
  queues, local-input arbitration, and secret-free latency summaries.
- The companion can intentionally run in a laptop browser. Rayslides also has
  an explicit identify/confirm presentation-display picker rather than assuming
  every external display is the projector.
- Windows networking retains its documented explicit `--presenter-host` and
  `--crowd-host` fallback when native adapter discovery cannot identify the
  intended interface.

### Showtime preflight and portable shows

- Showtime reuses parser, renderer, media, reusable-definition, display,
  Presenter, Crowdplay, and bounded rehearsal-health truth. Results are grouped
  into blockers, warnings, and notes with direct repair actions.
- Replacing the live document through a macOS Finder/Open With event now
  invalidates any visible preflight result and regenerates it after the new
  renderer graph commits, so Showtime cannot display readiness for the prior
  deck.
- `--showtime-report=FILE` provides stable CI JSON. Create portable show copies
  literal image, video, and custom-font dependencies, resolves basename
  collisions deterministically, rewrites only the copy, then independently
  reopens and preflights it.

### Small authoring floor

- Studio now covers exact multiline text, horizontal/vertical text alignment,
  rectangles and rounded corners, lines and arrows, image/video media,
  visibility, locking, opacity, ordering, alignment/distribution, and
  clockwise object rotation.
- Rotation is vertically complete across source, canvas handles with 15° Shift
  snapping, painted hit testing, Properties, reusable/local ownership,
  shortest-arc morphing, smart guides, Showtime bounds, screenshots, and PDF.
- Compatible multi-selection Properties edits are atomic: the whole edit is
  refused if any selected owner is unsafe or the property does not apply to
  every item.

### Verification recorded 2026-08-22

- 549/549 tests pass in ReleaseSafe on macOS and native Debian arm64.
- Accepted compact, default, large, and 160-slide incremental Studio visual
  baselines pass. The macOS harness moved and verified every exact test window
  as floating on its workspace-12 isolation Space before opening the capture
  gate.
- The packaged macOS app created, reopened, preflighted, and captured a portable
  media-rich show outside the checkout.
- A copied bundle received a LaunchServices document event for a copied show
  outside the checkout, loaded its relative PNG and MP4, and refreshed the
  initially visible Showtime report to `READY FOR SHOW` with 9 render
  fragments, 2 assets, and 1 reusable definition.
- A live packaged-app Presenter session paired from a fresh QR and recovered
  from a suspended/resumed host while retaining mode and notes.
- A copied packaged Presenter passed 430×932 portrait and 932×430 landscape
  browser simulation without horizontal overflow, while 1280×800 retained the
  laptop layout. Navigation, pointer, drawing, Clear, projected-stroke output,
  fail-safe reconnect controls, and same-tab QR recovery exercised the shipped
  server/client path. A final clean Chrome geometry pass asserted that the
  landscape surface and Clear action both end above fixed navigation. These
  measurements do not replace physical-phone QA.
- The rebuilt copied Presenter also paired in Mobile Safari on an iPhone 17 Pro
  iOS 26.5 Simulator. Simulated taps and a finger drag exercised navigation,
  Draw, Clear, and projected-stroke delivery; compact landscape Pointer/Draw
  kept the complete 16:9 surface above navigation. The same talk reconnected
  after a full Simulator reboot with its timer still running. This is WebKit
  and simulated-device evidence, not physical-phone, hotspot, Android,
  sleep/wake, latency, or phone-to-projector proof.
- A copied packaged app used the production identify/confirm path on a
  physically connected LG HDR 4K second display (3840×2160 at 60 Hz), then
  produced a visually reviewed Showtime capture. A combined LAN run returned
  200 from Presenter page/health and Crowdplay page/health, while an
  unauthenticated Presenter state request correctly returned 401.
- Native Debian arm64 built and launched under Xvfb/llvmpipe, probed real image
  and video assets with ffmpeg/ffprobe, and produced a visually reviewed
  `READY FOR SHOW` capture. A headless container has no physical ALSA device, as
  expected.
