# Rayslides Presenter Companion roadmap

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

### Draw — later tranche

- Remote drawing follows Pointer only after pointer latency and disconnect
  safety are proven.
- Drawing must be explicitly armed and visually unmistakable.
- Stroke begin/move/end, clear, and an undo story must be designed before this
  mode ships; accidental marks while scrolling notes are unacceptable.
- Existing laptop-side drawing remains unchanged throughout earlier tranches.

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
- Revision polling remains the state transport. Pointer motion currently uses
  sequenced HTTP updates capped by the client at roughly 30 Hz, with a single
  in-flight request and only the newest pending value retained. A later
  persistent transport is justified only by physical-device measurement and
  must preserve the same bounded, disconnect-safe handoff.
- The main renderer produces a 640x360 authenticated JPEG when slide semantics,
  reveal state, source, or Crowdplay state changes. Active transitions refresh
  at up to 5 fps; stable slides cause no continuing GPU readback or image
  encoding.

The initial presenter snapshot should contain at least:

- session ID and monotonic revision;
- zero-based current slide and total slide count;
- visible step and total step count;
- current notes and next-slide notes;
- timer state and server time;
- preview readiness and a monotonic rendered-preview revision;
- companion capabilities, allowing Pointer or later features to be hidden when
  unavailable.

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
- [ ] Detect usable local addresses and refresh pairing after switching between
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
- [x] Add begin/move/end handling, latest-value-wins coalescing, rate limits,
  disconnect release, and local/remote input arbitration.
- [ ] Complete physical-phone portrait/landscape rotation and projector
  letterboxing QA. Normalized browser gestures and fitted-slide mapping have
  automated coverage.

Exit gate: while walking around, the presenter can point naturally at the
projected slide, with no stuck laser and no replayed stale motion. Target normal
LAN latency is under 150 ms at the 95th percentile.

### 5. Remote drawing and optional desktop reuse

- [ ] Design and implement explicitly armed remote drawing only after Pointer is
  proven reliable.
- [ ] Let the same responsive companion run in a laptop browser for presenters
  who intentionally use extended displays.
- [ ] Consider projector selection/identification for the single rayslides
  window; do not infer that every external display is necessarily the beamer.

Native multi-window presenter mode remains a separate future decision and is
not required to complete this roadmap.

## Release confidence

Each tranche requires focused unit/integration coverage plus real-device QA.
The final workflow must be exercised with macOS screen mirroring, a physical
phone, a representative clicker, animations, local drawing/laser input, phone
sleep/wake, browser reload, Wi-Fi interruption, iPhone and Android hotspot
routing, and a complete offline talk.

The feature is complete when:

- pairing takes less than a minute and never exposes the QR to the audience;
- note changes arrive within one second under normal LAN conditions;
- repeated or delayed commands cannot advance twice;
- losing the phone or local server leaves rayslides fully controllable;
- unauthorized audience requests cannot retrieve notes or issue commands;
- remote pointer release is fail-safe; and
- no external account, app installation, Internet connection, or second
  rayslides process is required.

## Explicit non-goals for this roadmap

- A cloud relay or hosted companion service.
- A required native mobile app or installable PWA.
- A second rayslides presenter binary.
- Native multi-window rendering before the phone workflow is complete.
- Audience access to notes, presenter commands, pointer, or drawing.
- Replacing existing clicker, keyboard, mouse, laser, or drawing controls.
