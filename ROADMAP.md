# Rayslides product roadmap

This roadmap records the active cross-product plan after the source-native
Studio, Presenter Companion, Crowdplay, semantic motion, native packaging, and
initial video playback foundations shipped. It is the durable ordering and
completion contract for the next phase of Rayslides.

The objective is to complete four topics, in dependency order:

1. first-class media authoring in Studio;
2. Presenter Companion venue resilience;
3. Showtime preflight; and
4. a bounded set of high-value authoring primitives.

Work is delivered in independently testable increments, but a topic is not
complete merely because its parser or renderer works.

## Product and completion rules

- `.sld` remains the readable source of truth. New authoring actions produce
  guarded, reparsable, undoable source edits without normalizing unrelated
  source.
- Shared media behavior has image/video parity. File picking, replacement,
  deck-relative path handling, geometry, fitting/cropping, missing-file
  feedback, selection, reuse, and diagnostics must not be built for video
  alone when the same operation applies to images. Autoplay, looping, poster
  time, audio, seeking, and other intrinsically temporal controls remain
  video-specific.
- Every new source-level feature is vertically complete wherever meaningful:
  parser/model, renderer/presentation, Studio creation, Objects and Properties,
  direct and shared ownership, local overrides and morph states, clipboard and
  history, Library previews, PNG/PDF export, Showtime diagnostics,
  documentation, automated tests, and proportionate live visual/device QA.
- Ambiguous generated or shared-source edits fail atomically and explain why.
- Presentation and export pixels remain independent from editor chrome.
- Portable output keeps an ordinary `.sld` file and ordinary assets. It must
  not introduce a second opaque authoring format.
- Each increment updates the checkboxes and explanatory record below as it
  ships, so implementation and roadmap cannot silently drift apart.

## 1. Implemented: first-class media authoring in Studio

Video playback currently supports poster frames, play/pause, stop, seeking,
looping, and presenter-controlled audio. This topic completes the authoring
surface and gives images every shared media affordance added along the way.

### 1.1 Shared media insertion

- [x] Add a one-shot Video creation tool beside Image, including command
  palette discovery, keyboard access, hover help, responsive layout, and
  deterministic diagnostics.
- [x] Add a native file-picking path for both Image and Video creation, with a
  portable in-app path-entry fallback where a platform picker is unavailable.
- [x] Accept image and video file drops as the same source-safe creation
  operation when the platform exposes dropped files.
- [x] Store the selected path relative to the named deck when safe; preserve a
  valid absolute path for untitled decks or assets that cannot be represented
  safely as deck-relative paths.
- [x] Insert, reparse, select, Undo, and Redo the new media object as one
  ordinary Studio transaction in base scenes and eligible GROUP/SLIDE
  definition scenes.

### 1.2 Shared and video-specific Properties

- [x] Show the effective media kind and path in Properties and provide Replace
  through the same image/video picker and path policy used for insertion.
- [x] Make image and video natural dimensions, explicit width/height, aspect
  preservation, fit, fill, crop, and focal position coherent in syntax,
  rendering, direct manipulation, Properties, and morph interpolation.
- [x] Expose `poster=`, `autoplay`, and `loop` for videos; provide a poster
  scrubber/preview that chooses a frame without changing playback start.
- [x] Add authored video volume/mute defaults while retaining the presenter's
  temporary runtime adjustment semantics.
- [x] Keep invalid drafts local to the field, preserve selection/focus across
  successful reparses, and make local/shared/reset ownership explicit.

### 1.3 Composition, export, and confidence

- [x] Support media additions and property edits through direct items, ITEM
  definitions, GROUP members, SLIDE definitions, local instance overrides,
  and morph states wherever the source ownership is unambiguous.
- [x] Preserve media semantics through copy/paste, duplication, detach,
  definition rename/use, cleanup dependency analysis, and Undo/Redo.
- [x] Render deterministic image frames and video posters in slide thumbnails,
  Library cards, definition preview/edit mode, Presenter preview, screenshots,
  and PDF export.
- [x] Report missing/unreadable files, unsupported image data, missing ffmpeg,
  probe/decode failures, unreachable poster times, and unavailable audio as
  actionable authoring diagnostics without replacing the live render graph.
- [x] Add focused parser/source-editor/Studio/renderer tests, compact/default/
  large visual coverage, a parser-clean media QA deck, and complete user docs.

Exit gate: an author can add, replace, configure, reuse, morph, save, reopen,
present, and export images and videos without editing source, while the source
remains concise and every shared media interaction behaves consistently.

Shipped increments:

- 2026-08-22: Image/Video insertion parity landed with the `VID` tool,
  Commands/keyboard/hover discovery, macOS native pickers plus portable path
  entry, canvas file drops, and shared relative-path conversion. The compact
  seven-tool toolbar was visually verified at 900×506; 484 automated tests
  pass.
- 2026-08-22: Properties now identifies `IMAGE` or `VIDEO`, shows the effective
  path, and exposes a separate source-preserving **Replace** action through the same picker/path
  boundary. A parser-clean `testslides/studio-media-authoring.sld` fixture and
  deterministic image/video Properties captures verify the real render graph.
- 2026-08-22: Image/video boxes now share backward-compatible Stretch, Fit,
  Fill, normalized focal-position, natural-dimension, direct/shared/morph
  model, rendering, and Studio controls. Compact (900×506) and default
  (1280×720) packaged-app captures verify both media kinds; 490 automated tests
  pass.
- 2026-08-22: Video Properties gained a compact Playback page for authored
  poster time and duration-aware scrubbing, autoplay, loop, mute, volume, and
  opacity. Authored audio defaults are restored on slide entry without taking
  away temporary presenter adjustments. Packaged-app captures verify the page
  at 900×506 and 1280×720; 493 automated tests pass.
- 2026-08-22: Media ownership is now explicit across reusable instances and
  morph states. Amber `R` affordances independently restore inherited image or
  video sources, Fit, focal position, poster, volume, autoplay, loop, and mute;
  shorthand boolean attributes remain safe through component inspection and
  clipboard validation. Compact packaged-app QA verifies filename-first source
  display and reset markers; 495 automated tests pass.
- 2026-08-22: Missing images and unavailable videos now retain selectable
  fallback geometry in Studio, show file/format or file/ffmpeg repair overlays,
  and keep filename-first source display plus Replace live. The overlays are
  excluded from presentation/export pixels. A parser-clean
  `testslides/studio-media-missing.sld` failure fixture and compact packaged-app
  capture verify recovery; 497 automated tests pass.
- 2026-08-22: Image and video creation now retains the generated author ID
  across reparse, so the new object remains selected in ordinary slides and in
  GROUP/SLIDE Definition mode. A six-case source-transaction matrix verifies
  both media kinds through insertion, parser reconstruction, definition-local
  selection, Undo, and Redo; 499 automated tests pass.
- 2026-08-22: Media composition now round-trips through direct items, ITEM and
  GROUP reuse, SLIDE shared/local layers, and qualified morph mutations.
  Complete image/video settings survive copy, paste, duplication, real parsed
  component/group detach, definition use/rename, safe cleanup, and history.
  Base GROUP members intentionally route through Definition mode or Detach;
  morph scenes use their qualified IDs. 503 automated tests pass.
- 2026-08-22: Passive video rendering now uses a separate immutable GPU poster
  texture, so active decoding cannot leak an arbitrary frame into slide cards,
  Library cards, Definition mode, Presenter preview, screenshots, or PDF
  export. Live playback is neither stopped nor rewound. Packaged-app Library
  preview and editable ITEM Definition captures verify the authored poster and
  filename-first Properties row; 504 automated tests pass.
- 2026-08-22: Media diagnostics now preserve renderer-owned geometry while
  distinguishing missing and unreadable files, image decode failure, missing
  ffmpeg/ffprobe, probe/codec and poster failure, out-of-range poster fallback,
  and absent audio streams. Blocking failures remain selectable repair boxes;
  recoverable poster warnings retain real pixels. Compact warning, default
  failure, and 1920×1080 Properties captures plus three parser-clean media QA
  decks and updated reference/Studio docs complete this confidence pass; 507
  automated tests pass.

## 2. Implemented software: Presenter Companion venue resilience

This topic finishes the remaining real-network and real-display boundaries
before Showtime presents them as readiness checks.

- [x] Detect usable local addresses instead of assuming one advertised host;
  explain loopback, link-local, VPN, and unreachable choices.
- [x] Refresh or explicitly re-pair after switching between venue Wi-Fi and a
  presenter-phone hotspot without leaking the previous capability.
- [ ] Measure command, pointer, and drawing latency on physical phones; retain
  bounded queues, latest-value-wins motion, retry safety, and fail-safe release.
  The companion now exposes bounded median/p95/failure instrumentation without
  secrets; the remaining gate is measurement on representative physical phones.
- [ ] Complete portrait/landscape, sleep/wake, reconnect, and projector
  letterboxing QA on representative iPhone and Android devices.
- [x] Let the responsive private companion intentionally run in a laptop
  browser for extended-display workflows.
- [x] Add explicit projector/display identification and selection for the
  single presentation window without assuming every external display is the
  projector.
- [x] Cover lifecycle changes, stale sessions, network loss, local controls,
  Crowdplay isolation, docs, and reproducible live QA.

Exit gate: a presenter can change networks, identify the projector, pair a
phone, walk through a complete offline talk, lose/reconnect the phone, and keep
safe local control throughout.

Shipped increments:

- 2026-08-22: Presenter now discovers and ranks active IPv4 interfaces, explains
  LAN/VPN/link-local/loopback reachability, cycles addresses with <kbd>N</kbd>,
  and automatically rotates the private capability when the advertised network
  changes. Re-pairing keeps the listener port but invalidates all stale state;
  stop/restart, race reauthorization, queue reset, and Crowdplay isolation have
  deterministic integration coverage.
- 2026-08-22: The same private client has an intentional laptop workflow:
  <kbd>L</kbd> copies the unlogged bearer link, wide layouts place current/next
  notes and slide/tools side by side, keyboard navigation works, and a bounded
  secret-free connection-health panel reports median/p95 delivery. A real
  desktop and sub-900-pixel browser session were exercised against the embedded
  server; 514 automated tests pass.
- 2026-08-22: A fresh packaged-app QR was paired against the embedded server in
  a real browser session. Pausing the exact host process drove the client to
  `Reconnecting…`, disabled navigation and pointer input fail-safe, and retained
  Draw mode and synchronized notes; resuming the same host returned to
  `Connected` without re-pairing or horizontal overflow. The pairing overlay
  also changed from waiting to connected without exposing its private
  capability. This is host/browser evidence, not a substitute for the remaining
  iPhone, Android, hotspot, sleep/wake, latency, and projector rehearsal.
- 2026-08-22: A copied packaged app completed a phone-viewport browser pass at
  430×932 portrait and 932×430 landscape. Both orientations stayed in the phone
  layout with visible tabs/navigation and no horizontal overflow; 1280×800
  retained the intentional laptop layout. Browser-driven Previous/Next,
  Pointer, Draw, and Clear reached the production queues, and the projected
  drawing was visually captured. Secret-free browser-to-laptop p95 was 2 ms
  for three commands, 4 ms for four pointer updates, and 46 ms for seven
  drawing updates. A suspended host disabled stale companion controls at
  `Reconnecting…` and restored them after resuming. Same-tab fresh and rotated
  QR fragments now reload the client instead of retaining an expired session.
  A final clean Chrome pass at 430×932, 932×430, and 1280×800 asserted no
  horizontal overflow, the correct phone/laptop breakpoint, and both the
  landscape surface and Clear action ending above fixed navigation.
  These are desktop-browser viewport and simulated-touch measurements, not
  physical-phone or phone-to-projector evidence.
- 2026-08-22: The rebuilt copied app was paired in Mobile Safari on an iPhone
  17 Pro iOS 26.5 Simulator. Native simulated taps exercised Previous/Next,
  mode switching, Draw, and Clear; a simulated finger drag appeared immediately
  on the phone surface and was visually captured on the Rayslides projection.
  Portrait kept the full phone companion, while short landscape Pointer/Draw
  now deliberately removes explanatory chrome, keeps the complete 16:9 surface
  and Clear action above fixed navigation, and leaves Notes unchanged. A full
  Simulator shutdown and boot reconnected the same talk with its running timer
  intact. This adds Mobile Safari/WebKit, orientation, gesture, and process-
  lifecycle evidence, but is not physical-phone touch, sleep/wake, hotspot,
  latency, Android, or phone-to-projector evidence; the two physical gates
  above remain unchecked.
- 2026-08-22: <kbd>D</kbd> and Studio Commands now open an explicit two-step
  display picker. It enumerates operating-system names, resolution, refresh,
  coordinates, selected/current state, supports identify/confirm/cancel, and
  restores the exact fullscreen mode without guessing which external display
  is the projector. Compact two-display visual QA, row hit-testing, window-fit
  tests, and the macOS package pass.
- 2026-08-22: The copied packaged app exercised the production identify/confirm
  path against the physically connected LG HDR 4K second display
  (3840×2160 at 60 Hz). The confirmed picker and Showtime were visually
  captured with the exact Rayslides windows verified floating on workspace 12.
  In a combined LAN run, Presenter page/health returned 200, unauthorized state
  correctly returned 401, and Crowdplay page/health returned 200 before both
  temporary listeners shut down.

## 3. Implemented software: Showtime preflight

Showtime turns all known presentation dependencies into one calm, actionable
readiness workflow. Checks must reuse parser/renderer/runtime truth rather
than maintaining a second approximation of the deck.

### 3.1 Deck and render checks

- [x] Traverse every logical slide, reveal endpoint, cumulative morph scene,
  reusable definition, and export endpoint without changing the live deck.
- [x] Report missing assets/fonts, unreadable media, missing glyphs, text
  overflow, duplicate/unstable IDs, invalid references, unsafe-area escapes,
  and content that cannot produce deterministic presentation/export pixels.
- [x] Distinguish errors that prevent presenting from warnings that are
  intentional or merely deserve review; every result links to its slide,
  object, definition, or source line when available.

### 3.2 Runtime, network, and display checks

- [x] Verify ffmpeg/ffprobe, required media streams/codecs, poster decoding,
  audio readiness, and representative seek/play behavior.
- [x] Verify selected display, resolution, aspect ratio, scaling,
  letterboxing, refresh/vsync, fullscreen transition, and preview isolation.
- [x] Verify Presenter and Crowdplay host/port availability, advertised LAN
  reachability, QR endpoints, capability separation, and measured round-trip
  health without exposing private notes or secrets.

### 3.3 Readiness and portable delivery

- [x] Present a resumable checklist with a clear **Ready for show** outcome and
  concise fixes for every failure.
- [x] Run a deterministic render-through that cannot mutate presentation,
  poll, history, selection, dirty, or media playback state.
- [x] Create an optional portable folder containing an ordinary `.sld` copy
  and its required assets, with collisions/external paths handled explicitly
  and the original deck untouched.
- [x] Re-open and preflight the portable copy as the final packaging gate.
- [x] Add headless diagnostics/report output, compact UI baselines, parser and
  renderer failure fixtures, docs, and reproducible local venue-style QA.
- [ ] Complete a physical phone/projector Showtime rehearsal at the final
  release gate; the software retains and reports the private client's bounded
  median/p95/failure evidence for that run.

Exit gate: before leaving for a venue, the author can prove that the exact deck,
assets, media runtime, phone services, and intended display path are ready—or
receive a short list of concrete blockers.

Shipped increments:

- 2026-08-22: Studio Commands gained a non-mutating Showtime overlay over the
  exact parser and renderer graph. It walks every base/reveal/morph scene plus
  independently materialized reusable definitions, reports media/font/glyph/
  layout/identity/display/network failures with source targets, and opens the
  selected slide/object or editable definition. Compact ready and eight-finding
  failure baselines verify the calm 900×506 workflow.
- 2026-08-22: `--showtime-report=JSON` now emits stable secret-free JSON and a
  nonzero blocker exit, including exact malformed-source line diagnostics.
  Presenter clients return only bounded latency counts, median/p95 values, and
  failures to the local service so the report can distinguish a listening
  server from a measured rehearsal; re-pairing clears the evidence.
- 2026-08-22: **Create portable show** and `--portable-show=DIR` copy an
  ordinary `.sld` plus literal image/video/custom-font dependencies, rewrite
  them under `assets/`, resolve basename collisions deterministically, refuse
  existing destinations, and independently re-open/render/preflight the copy.
  A real media-rich folder and its generated report passed; 519 automated tests
  pass. Physical phone/projector rehearsal remains an explicit release gate.

## 4. Implemented: bounded small authoring floor

These are deliberately ordered, individually shippable vertical increments.
They add common conference-slide primitives without turning `.sld` into a
browser layout engine or Studio into a general illustration program.

### 4.1 Typography and alignment

- [x] Add SDF-based or equivalently crisp presentation-font scaling across
  Studio zoom, high-density displays, fullscreen, screenshots, and export.
- [x] Add horizontal and vertical text alignment with source syntax,
  Properties, shared/local ownership, morph behavior, previews, and tests.
- [x] Add atomic common-property editing for compatible multi-selections,
  retaining truthful Mixed values and refusing the complete batch when any
  selected source owner is unsafe.

### 4.2 Focused visual primitives

- [x] Add lines and arrows with endpoints, stroke width/color, optional arrow
  heads, Studio creation/handles, reuse, morphing, export, and Properties.
- [x] Add rounded rectangle corners as an extension of the existing bounded
  color shape rather than a parallel shape system.
- [x] Add rotation for eligible text, shape, image, video, line, and reusable
  content, including hit-testing, selection bounds, guides, handles,
  interpolation, and exact Properties editing.
- [x] Add SVG as a first-class image source with deterministic raster/display
  behavior, sizing, previews, export, missing-resource diagnostics, and the
  same picker/replacement workflow as raster images.

Exit gate: each primitive is source-native, visually editable, reusable,
morph-aware where meaningful, export-safe, documented, and covered by
round-trip plus compact/default/large visual tests.

Shipped increments:

- 2026-08-22: Presentation text moved to crisp distance-field rendering;
  horizontal/vertical text alignment and atomic common multi-selection edits
  now share parser, source ownership, morph, Properties, and history behavior.
- 2026-08-22: Source-native `@line` objects gained optional start/end arrows,
  stroke-aware hit testing, endpoint handles, reusable/morph support, export,
  and exact Properties. Rounded `radius=` shapes and first-class SVG image
  sources landed through the same authoring and diagnostic surfaces. SVG text
  remains intentionally unsupported by the embedded NanoSVG subset.
- 2026-08-22: `rotation=` completed the floor for text, color shapes, images,
  videos, and lines. Studio provides painted-geometry hit testing, rotated
  selection bounds and smart-guide targets, a canvas handle with 15° Shift
  snapping, exact Properties, reusable/local reset semantics, shortest-arc
  morph interpolation, export rendering, and rotation-aware Showtime bounds.
  The parser/source/Studio/renderer regression suite now passes 549 tests, and
  `testslides/studio-rotation.sld` verifies the real packaged render path.
- 2026-08-22: macOS LaunchServices document replacement was exercised from a
  copied bundle and copied portable show outside the checkout. The external
  deck and its relative PNG/MP4 loaded successfully; a visible Showtime report
  was invalidated and regenerated after the new render graph committed,
  yielding `READY FOR SHOW` with 9 fragments, 2 assets, and 1 definition.

## Next: visual motion authoring

The next Studio phase makes every reveal, morph-state, and transition
capability of the `.sld` format visually authorable and previewable. It is
sequenced in the [Motion Studio roadmap](MOTION_STUDIO_ROADMAP.md) and
follows the same completion rules as the topics above.

## Final release gate

- [x] Run the complete unit and round-trip suite in ReleaseSafe.
- [x] Pass visual/performance baselines and review intentional updates.
- [x] Exercise the packaged macOS application outside the checkout with a
  portable media-rich deck, Presenter Companion, Crowdplay, and a projector or
  representative second display. A copied bundle loaded relative media,
  confirmed the connected LG display, preflighted it, and ran Presenter plus
  Crowdplay concurrently over the LAN; the earlier packaged-browser rehearsal
  paired and recovered through host suspend/resume.
- [x] Complete the representative Linux portability check used by this plan:
  native Debian arm64 ReleaseSafe build, 549/549 tests, CLI launch, and an
  Xvfb/llvmpipe Showtime run with ffmpeg/ffprobe and real image/video assets.
- [x] Reconcile this roadmap, the Studio and Presenter roadmaps, reference
  documentation, visual guide, test decks, and release notes with shipped
  behavior.

Release evidence recorded 2026-08-22: `release-confidence` passes 549/549
tests in ReleaseSafe; the accepted compact/default/large/incremental Studio
baselines pass, including a 160-slide one-slide incremental rebuild, after the
harness moves and verifies every exact Rayslides window as floating on its
workspace-12 automation-isolation Space; the
ReleaseSafe macOS app packages successfully and independently creates,
re-opens, preflights, and visually captures a media-rich portable show from
`/tmp`; a copied bundle also accepts the portable deck through a LaunchServices
document event, loads its relative image/video, and refreshes visible Showtime
state from the replacement document. A disposable Debian arm64 host also builds
and passes 549/549 ReleaseSafe tests, launches
the native ELF, probes the media-rich fixture through ffmpeg/ffprobe, and
captures a visually reviewed 1280×720 Showtime screen under Xvfb/llvmpipe. It
reports `READY FOR SHOW`; its only environment-specific runtime warning is the
expected absence of a physical ALSA audio device in the headless container.
The copied packaged app additionally confirmed and preflighted a physically
connected 3840×2160/60 Hz LG second display while Presenter and Crowdplay
served healthy, isolated LAN endpoints. A separate copied-bundle browser pass
covered 430×932/932×430 responsive layouts, production navigation/pointer/draw
delivery, projected drawing, same-tab re-pairing, and host suspend/resume with
fail-safe control disabling. A subsequent iPhone 17 Pro iOS 26.5 Simulator run
used Mobile Safari in portrait and landscape, projected and cleared a simulated
finger stroke, verified the complete compact landscape surface above fixed
navigation, and reconnected after a full Simulator reboot without resetting
the talk timer. Simulator evidence does not close physical-phone lifecycle,
latency, hotspot, Android, or real-projector gates. Windows runtime is not part
of this four-topic plan.

The four-topic objective is complete only when every topic and the final
release gate above are complete. Deferred ideas such as nonlinear navigation,
reactive live-data bindings, persistent audience content, an agent protocol,
or presentation replay are outside this plan.
