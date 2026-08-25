# Rayslides release notes

## Unreleased — four-topic roadmap completion

The software work for the current four-topic roadmap is implemented. This is
not yet a release declaration: physical-phone venue rehearsal and a real
projector pass remain open in
[`ROADMAP.md`](ROADMAP.md).

### Visual motion authoring in Studio

- A third inspector tab, **Motion**, edits reveals, morph-state timing, and
  slide transitions through the ordinary undoable source path. Its Reveal
  section offers None/Click/Auto/Click>Auto triggers, effect, By
  item/line/bullet, DELAY/AFTER/DUR, easing, **Build bullets**, and
  Remove/Cancel/Reset; multi-selection patches every item in one step.
- The State section edits LABEL/AFTER/DUR, Click/Auto, and easing of the
  active morph state, lists the changes in that state, marks cross-fading
  objects, and offers **Reset** and **Exit L/R/U/D** for the selected
  object.
- The Transition section chooses Inherit/None/Appear/Fade/Slide L/R/U/D,
  duration, and easing for the slide's incoming transition, reports whether
  the value comes from this slide, a template, or the deck default, and
  writes or clears the deck default. Alt edits a `@pushslide` template
  instead of the instance.
- The bottom timeline shows the `IN` transition chip, BASE, one BUILD card
  per reveal with step chips, and the STATE cards; `[`/`]` cycle through all
  of them, and `<`/`>` on a BUILD card reorders builds without changing
  paint order.
- A live preview plays the slide's real reveal, morph, and transition timing
  on the canvas from the selected scene: Play/Pause, Stop, Loop, a
  scrubber, and a time readout in the timeline; Shift+Space and Esc on the
  keyboard. Click-gated steps use a fixed 0.75 s preview gap.
- The canvas shows numbered build badges in BASE and, in a state, dashed
  ghosts of previous bounds, motion paths, and NEW/EXIT/SHOW chips (**Toggle
  motion ghosts**). All of it is editor chrome and never reaches
  presentation, export, or Presenter output.
- New palette commands: Show Motion, Build bullets one by one, Remove
  reveal, Play or pause preview, Stop preview, Loop preview, Toggle motion
  ghosts, Reset object in this state, Edit slide transition. New launch
  hooks: `--diagnostics-motion=ID`, `--diagnostics-timeline-step=N`,
  `--diagnostics-slide=N`, `--diagnostics-motion-preview=SECONDS`,
  `--diagnostics-motion-state=N`, `--diagnostics-motion-transition`.
- Every Motion control carries delayed hover help, and Showtime adds three
  motion findings: an automatic run longer than 30 s (info), a reveal on a
  `visible=false` object (warning), and a morph state that changes nothing
  (info).
- Format additions: `delay=SECONDS|click`, `ease=`, and `order=N` on reveals;
  `ease=` on slide boundaries; deck defaults `@transition=`,
  `@transition_duration=`, and `@transition_ease=`.
- Behavior change: `anim=none` / `@anim(none)` now means "no reveal" (it
  used to create an instant click step), and unknown keys on `@anim` and
  `@state(morph)` are parser errors instead of silently ignored tokens.

Verification recorded 2026-08-25 for motion authoring: 585 tests pass in
`zig build test` and `zig build release-confidence`; ten ReleaseSafe Studio
baselines (compact/default/large, including six motion scenarios on
`testslides/studio-motion-qa.sld`) match on macOS; Showtime reports the QA
deck ready. A live projector run of the QA deck remains a manual step.

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
