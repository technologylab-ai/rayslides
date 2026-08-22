# Rayslides Presenter Companion roadmap

The remaining venue-resilience work in this document is sequenced by the
top-level [product roadmap](ROADMAP.md), which then feeds those completed
runtime capabilities into Showtime preflight.

Status: accepted product direction, 2026-08-19.

This file records the intended presenter workflow and implementation order so
future work does not drift toward a native dual-window system before the
phone-first experience is complete.

## Product decision

Rayslides will provide a mobile-first **Presenter Companion** as a self-contained
web app served by the running rayslides process. It is not another binary, does
not require installation or an account, and does not use an external service.

The primary workflow is the one already used for real talks:

1. Open the deck and choose **Pair Phone** while the screen is still private.
2. Scan a fresh, session-specific QR code with the presenter's phone.
3. Enable display mirroring and put rayslides fullscreen on the laptop/beamer.
4. Keep rayslides focused so its keyboard, clicker, mouse, drawing, and laser
   controls continue to behave exactly as they do today.
5. Read notes and control the presentation from the phone while moving around
   the stage.

Venue Wi-Fi is optional: the presenter can enable a hotspot on the phone, join
that network from the laptop, and pair over the resulting private local network.
This hotspot path is a first-class workflow, not merely a troubleshooting tip.

The same responsive web app may later be opened in a laptop browser when using
extended displays, but that is a secondary workflow. A native second presenter
window is not part of the initial plan.

## Non-negotiable principles

- Rayslides remains the only executable and hosts every companion asset locally.
- Existing keyboard, clicker, mouse, drawing, and laser input remains available.
- The companion is additive: failure to bind, pair, or reconnect must never
  prevent the deck from presenting normally.
- Pairing is explicit. A deck containing notes must not silently expose them on
  the network merely because it was opened.
- The presenter QR is shown only in Studio or a private pre-presentation setup
  screen, never as an audience-visible slide.
- Speaker notes never appear in Crowdplay responses or any unauthenticated
  endpoint.
- Presenter commands go through the same playback operations as local input, so
  animation gating, reverse behavior, transitions, and auto-reveal semantics do
  not fork into a second implementation.
- The phone client is usable without Internet access and loads no CDN assets.
- Phone sleep, rotation, brief Wi-Fi loss, or a browser reload must recover
  without disturbing the projected presentation.
- Network-interface changes are detected before pairing; the setup view shows
  the currently reachable address and regenerates the QR rather than retaining
  an obsolete venue-network URL.
- Remote pointer control is committed scope after notes/navigation, not a
  stretch goal.

## Intended companion experience

The phone UI has three intentionally distinct surfaces:

### Notes

- Current slide notes are the primary content.
- A compact next-slide cue is available without overwhelming the current notes.
- Slide number/count, elapsed time, clock, and connection state remain visible.
- Previous and Next are large, deliberate controls fixed within thumb reach.
- The browser requests a screen wake lock where supported and explains the
  fallback where it is not.
- Reconnection is automatic and never resets the talk timer or presentation.

### Pointer

- An explicit mode switch replaces the notes area with a touch surface mapped
  to rayslides' logical 1920x1080 slide space.
- The surface shows a compact screenshot of the current rendered slide,
  including its visible reveal/transition and Crowdplay state, so the presenter
  can see exactly where the software laser will land.
- Press/drag displays the software laser; releasing the touch hides it.
- Coordinates account for aspect-fit letterboxing and remain normalized on the
  wire so phone size and orientation do not affect the slide mapping.
- Pointer motion is latest-value-wins. Stale motion is discarded rather than
  replayed after network congestion.
- Disconnecting, backgrounding the page, or leaving Pointer mode immediately
  releases the remote laser.
- Local mouse/keyboard laser controls continue to work and take predictable
  precedence over remote pointer state.

### Draw

- A third, explicit mode keeps drawing visually unmistakable and prevents
  accidental marks while scrolling notes or using the software pointer.
- The phone draws into a local canvas immediately, then mirrors normalized
  begin/move/end events to a bounded main-thread queue.
- A deliberate Clear button removes both phone and projected strokes. The
  initial mode favors one obvious recovery action over a hidden undo history.
- Drawings persist through reveals, clear on logical slide changes, and time
  out an abandoned stroke if the browser loses its touch-end event.
- Existing laptop-side drawing remains available and local `C` clears both
  annotation layers.

Pointer and Draw both retain a compact, scrollable copy of the current speaker
notes below their control surface. This keeps the active stage tool usable while
still providing a glanceable prompt without switching back to Notes mode.

## Source format and authoring

Speaker notes belong to the logical slide and remain ordinary `.sld` source.
The initial format should use an unambiguous multiline block, provisionally:

```text
@notes
Open with the customer story.
Pause after the graph, then ask for questions.
@endnotes
```

The implementation must settle and test exact placement, duplicate-block,
template, and malformed-block behavior before declaring the syntax stable.
Initial notes are per-slide rather than per-animation-step, but presentation
state includes the visible step from day one so step-specific cues can be added
later without replacing the protocol.

Notes must:

- survive every Studio source edit, save/copy, undo/redo, reload, and recovery;
- never affect presentation rendering, screenshots, PDF export, or render-graph
  fingerprints;
- support a multiline Notes editor in Studio using the same transactional,
  source-native editing model as the rest of Studio;
- remain readable as plain source without an opaque project format.

## Runtime architecture

Crowdplay supplied useful patterns—an embedded browser client, LAN listener,
QR rendering, bounded HTTP handling, session identity, and revision polling—but
the accepted implementation uses two completely independent servers. This
small amount of duplication buys a hard privileged/audience boundary and lets
either lifecycle fail or stop without affecting the other.

```text
Presenter phone ── authenticated state/preview/commands/pointer ── port 7332 ─┐
                                                                               v
Crowdplay phones ───────── unauthenticated audience API ── port 7331 server    main-thread queues
                                                                               |
                                                                               v
                                                        playback + laser/drawing state
```

The boundaries are:

- A presentation-state component owns session revision, current slide, visible
  step, slide count, current/next notes, and timer state.
- Crowdplay keeps its existing audience store, routes, port, and authorization
  model in a separate listener with no presenter routes or notes.
- The HTTP worker never mutates `G`, playback, renderer, or laser state. It
  validates and enqueues bounded commands; the main loop consumes them.
- Navigation commands call the same forward/reverse presentation functions used
  by local input instead of setting slide indices directly.
- Commands carry sequence IDs and are retry-safe, so a reconnect or repeated
  request cannot advance twice.
- Revision polling remains the state transport. Pointer and drawing motion use
  sequenced HTTP updates capped by the client at roughly 30 Hz, with a single
  in-flight request and only the newest pending move retained. Drawing lifecycle
  events enter a separate bounded queue so begin/end cannot be replayed as
  pointer state. A later persistent transport is justified only by physical-
  device measurement and must preserve the same bounded, disconnect-safe handoff.
- The main renderer produces a 640x360 authenticated PNG when settled slide
  semantics, reveal state, source, or Crowdplay state changes. Active animation
  frames perform no GPU readback or image encoding; the first settled frame is
  published immediately afterward.

The initial presenter snapshot should contain at least:

- session ID and monotonic revision;
- zero-based current slide and total slide count;
- visible step and total step count;
- current notes and next-slide notes;
- timer state and server time;
- preview readiness and a monotonic rendered-preview revision;
- companion capabilities, allowing Pointer and Draw to be disabled when local
  presentation state makes them unavailable.

## Pairing and privacy

- Generate a cryptographically random presenter capability for each rayslides
  process/session and invalidate it on shutdown or explicit unpair.
- Keep the capability out of ordinary Crowdplay URLs and responses.
- Prefer placing the pairing secret in the URL fragment so it is not sent while
  fetching the static presenter page; use it only for authenticated presenter
  API requests.
- Return `Cache-Control: no-store` for the page and all presenter state.
- Serve rendered slide previews only through the same capability-authenticated,
  `no-store` Presenter API; Crowdplay must expose neither the bytes nor a route.
- Do not log the capability or notes.
- Reject presenter commands without the capability and validate request origin,
  method, content type, size, sequence, and rate limits.
- Document honestly that a random capability prevents guessing and accidental
  audience access, while plain local HTTP does not protect against a malicious
  network observer.

## Delivery tranches

### 1. Notes foundation

- [x] Add notes to the parsed slide model and finalize the block syntax.
- [x] Cover parser errors, lifetime ownership, reload, source round trips, and
  render/export isolation with tests.
- [x] Add a transactional multiline Notes editor to Studio.
- [x] Add notes to a representative test deck.

Exit gate: notes can be authored visually or in source and cannot change any
projected/exported pixels.

### 2. Private phone companion

- [x] Introduce presentation state independently from Crowdplay poll state.
- [x] Add explicit Pair Phone/start/stop lifecycle and private QR rendering.
- [x] Detect usable local addresses and refresh pairing after switching between
  venue Wi-Fi and a presenter-phone hotspot.
- [x] Embed and serve the responsive Notes UI with no external dependencies.
- [x] Synchronize slide, visible step, current/next notes, timer, and connection
  state through revision polling.
- [x] Implement wake-lock, reconnect, rotation, and stale-session behavior.

Exit gate: after pairing privately, a presenter can enable mirroring, fullscreen
rayslides, and read synchronized notes for an entire talk without touching the
laptop UI.

### 3. Remote presentation control

- [x] Add authenticated, sequenced Previous and Next commands.
- [x] Feed commands into a bounded main-thread queue and reuse local playback
  semantics.
- [x] Provide clear accepted/rejected feedback and optional haptics.
- [x] Preserve keyboard, clicker, mouse, and auto-reveal behavior while the phone
  is connected or disconnected.

Exit gate: phone navigation and local navigation are interchangeable, including
animations, reversals, transitions, retries, and reconnects.

### 4. Remote software pointer

- [x] Add the explicit Pointer surface, live rendered-slide preview, and correct
  logical-slide mapping.
- [ ] Measure HTTP motion delivery before choosing the persistent transport;
  optimize for low latency without weakening boundedness or cancellation.
  The self-contained companion now keeps a bounded, secret-free median/p95
  delivery report; representative physical-phone runs remain required.
- [x] Add begin/move/end handling, latest-value-wins coalescing, rate limits,
  disconnect release, and local/remote input arbitration.
- [ ] Complete physical-phone portrait/landscape rotation and projector
  letterboxing QA. Normalized browser gestures and fitted-slide mapping have
  automated coverage.

Exit gate: while walking around, the presenter can point naturally at the
projected slide, with no stuck laser and no replayed stale motion. Target normal
LAN latency is under 150 ms at the 95th percentile.

### 5. Remote drawing and optional desktop reuse

- [x] Add an explicitly armed Draw surface with immediate phone-side feedback.
- [x] Mirror normalized begin/move/end events through a bounded authenticated
  queue and render them without triggering preview captures.
- [x] Add clear, slide-change cleanup, lost-touch timeout, and local-control
  arbitration.
- [x] Let the same responsive companion run in a laptop browser for presenters
  who intentionally use extended displays.
- [x] Add projector selection/identification for the single rayslides
  window; do not infer that every external display is necessarily the beamer.

Native multi-window presenter mode remains a separate future decision and is
not required to complete this roadmap.

## Release confidence

Each tranche requires focused unit/integration coverage plus real-device QA.
The final workflow must be exercised with macOS screen mirroring, a physical
phone, a representative clicker, animations, local drawing/laser input, phone
sleep/wake, browser reload, Wi-Fi interruption, iPhone and Android hotspot
routing, and a complete offline talk.

Host/browser evidence recorded 2026-08-22: a fresh packaged-app QR paired with
the embedded client; a suspended host produced `Reconnecting…` with navigation
and pointer input disabled, retained the selected Draw mode and synchronized
notes, and recovered to `Connected` without re-pairing when the host resumed.
The tested desktop layout had no horizontal overflow. This narrows the software
and live-host risk while leaving every physical-phone, hotspot, sleep/wake,
latency, clicker, and projector check below intact.

Phone-viewport browser evidence recorded 2026-08-22: the copied packaged client
was exercised at 430×932 portrait and 932×430 landscape. Both remained in the
phone layout, kept tabs and fixed navigation visible, and had no horizontal
overflow; 1280×800 still selected the laptop layout. Browser-driven
Previous/Next, Pointer, Draw, and Clear reached the production queues, with a
projected stroke visually verified. The bounded report measured p95 delivery of
2 ms for three commands, 4 ms for four pointer updates, and 46 ms for seven
drawing updates. Host suspension disabled stale controls and release state at
`Reconnecting…`; resume restored them. Fresh and rotated capability fragments
also recover in an already-open tab. A final clean Chrome geometry pass at
430×932, 932×430, and 1280×800 asserted the intended phone/laptop breakpoint,
no horizontal overflow, and the complete landscape surface plus Clear action
above fixed navigation. This covers responsive layout and browser event paths
only, not hardware touch, hotspot routing, or phone-to-projector latency.

Mobile Safari Simulator evidence recorded 2026-08-22: the rebuilt copied app
paired with an iPhone 17 Pro iOS 26.5 Simulator. Native simulated taps and a
finger drag exercised navigation, mode switching, Draw, Clear, and production
projected-stroke delivery. Portrait retained the full phone workflow; short
landscape Pointer/Draw used a compact workspace with the complete 16:9 surface
and Clear action above fixed navigation, while Notes retained its normal
content layout. Mobile Safari reconnected to the still-running talk after a
full Simulator shutdown and boot and showed the continuing timer. This proves
WebKit rendering plus simulated orientation, gesture, and process-lifecycle
behavior; it does not prove a physical digitizer, actual phone sleep/wake,
mobile Chrome, venue Wi-Fi/hotspot behavior, representative physical latency,
or phone-to-projector pixels, so the physical-device boxes remain open.

Second-display evidence recorded 2026-08-22: a copied packaged app invoked the
production display identify/confirm path on the physically connected LG HDR 4K
display (3840×2160 at 60 Hz) and preflighted it through Showtime. In the same
LAN/display setup, the Presenter page and health endpoint returned 200, an
unauthenticated state request returned 401, and the independent Crowdplay page
and health endpoint returned 200. This completes the representative-display
and combined-host boundary, but does not replace the remaining physical-phone
latency, orientation, sleep/wake, hotspot, and real-projector rehearsal.

The feature is complete when:

- pairing takes less than a minute and never exposes the QR to the audience;
- note changes arrive within one second under normal LAN conditions;
- repeated or delayed commands cannot advance twice;
- losing the phone or local server leaves rayslides fully controllable;
- unauthorized audience requests cannot retrieve notes or issue commands;
- remote pointer release and drawing termination are fail-safe;
- no external account, app installation, Internet connection, or second
  rayslides process is required.

## Explicit non-goals for this roadmap

- A cloud relay or hosted companion service.
- A required native mobile app or installable PWA.
- A second rayslides presenter binary.
- Native multi-window rendering before the phone workflow is complete.
- Audience access to notes, presenter commands, pointer, or drawing.
- Replacing existing clicker, keyboard, mouse, laser, or drawing controls.
