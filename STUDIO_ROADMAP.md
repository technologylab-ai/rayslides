# Rayslides Studio roadmap

Studio turns the ordinary `.sld` document into a visual authoring surface
without introducing a second, opaque project format. This file records the
direction and the order of work so the plan survives individual implementation
sessions.

## Product principles

- `.sld` remains the source of truth. A completed GUI action must produce a
  readable, reparsable, undoable source edit.
- Source ownership stays explicit. Direct items, component instances, slide
  templates, local instance overrides, and morph states must not be confused.
- Ambiguous edits fail atomically and explain why; Studio never silently edits
  only the convenient subset.
- Presentation and export behavior remain independent from editor chrome.
- Prefer focused authoring aids—guides, exact properties, reusable components,
  and semantic operations—over a general-purpose layout engine.
- Every tranche includes headless round-trip tests and visual QA at compact,
  default, and large window sizes.

## Completed foundation

- Source provenance, guarded source rewriting, atomic save/copy, undo/redo,
  dirty-state recovery, and hot-reload protection.
- Direct manipulation with move, resize, smart guides, grid snapping, aspect
  lock, exact geometry, alignment, distribution, multi-select, and marquee.
- Text, bullets, images, rectangles, item colors/backgrounds, font size,
  opacity, locks, paint-order changes, copy/paste, duplication, and deletion.
- Slide organization, reusable element and slide-template libraries, template
  promotion, local template-instance overrides, shared edits, and semantic
  morph-state editing.
- Responsive docked Studio chrome, Focus Canvas, and a dedicated embedded UI
  font, while presentation and export retain the full slide viewport. The
  complete chrome now scales coherently from 1x to 2x on large logical window
  surfaces: docks, rows, timeline cards, hit targets, and type all grow
  together without changing the compact-window floor.
- A source-aware Objects inspector for the active base or morph scene. It shows
  every meaningful object in paint order, including hidden, fully
  transparent, and locked items that cannot be reached reliably on the canvas.
- Ordered multi-selection synchronized between the object list and canvas.
- Concise ownership and type badges: direct, component, template,
  local override, inherited, morph-born, background, and Crowdplay.
- Atomic, undoable visibility and locking controls, including `opacity=0`
  recovery from the Objects list.
- Safe layer-order operations, pinned background barriers, and actionable
  explanations when another source barrier atomically refuses an operation.
- Inline Properties fields for text, exact geometry, foreground/background,
  font size, and opacity, with keyboard traversal, caret-following scrolling,
  and validation that retains invalid drafts without touching source/history.
- Compact color editing, truthful common/Mixed multi-selection values, and
  selection/focus preservation across non-structural property edits.
- Synchronized redraw, atomic render-graph replacement, explicit render-text
  ownership, and opt-in frame/rebuild/arena diagnostics for live authoring QA.

## Completed tranche: Reusable composition

- [x] Inspect exact component, slide-template-instance, and current morph-state
  overrides; reset one property by removing every contribution from that
  source layer so the inherited value genuinely resurfaces.
- [x] Detach a source-safe single `@pop` component instance into one fully
  materialized direct `@box`, retaining formatting, animation ownership,
  selection, history, and renderer semantics.
- [x] Add the explicit reusable-group grammar and parser model:
  `@pushgroup NAME` … `@endgroup`, used by `@popgroup NAME id=INSTANCE`, with
  member IDs namespaced as `INSTANCE.MEMBER`.
- [x] Promote a contiguous selected group into one group definition and one
  group instance without changing paint/reveal order.
- [x] Discover, place, rename, and safely detach reusable groups through the
  Library and Properties UI.
- [x] Improve dependency-aware rename, delete, and fixed-point cleanup across
  element, group, and slide-template definitions.

The explicit group syntax is intentional. Existing `@push`/`@pop` represents
exactly one item, so Studio will not pretend that several unrelated component
definitions form one reusable object. The first group release uses absolute
member coordinates and requires literal, stable member and instance IDs;
translation/scaling overrides can build on that source contract later.

Studio now exposes reusable groups honestly throughout the authoring loop:
multi-select contiguous authored items and choose **Reuse** to create one
definition/instance transaction; Library rows carry an explicit **GROUP**
badge and place source-order-resolved instances; Properties identifies group
members and detaches the complete instance into ordinary local boxes. Rename,
unused deletion, placement, promotion, and detach all preserve exact definition
provenance and fail atomically when source ownership is ambiguous.

The Library's **Clean** action first previews the exact number of unreachable
definitions, then requires an explicit **Apply**. Its source-order dependency
graph follows live uses through element, group, and direct slide-template
definitions to a fixed point and commits one undoable rewrite. Definitions
whose parser-context ownership cannot be proven remain in source and are
reported as blocked rather than guessed away.

## Completed tranche: New-deck experience

- [x] Open no-file launches directly into a visual starter chooser inside
  Studio, with click and 1–4 keyboard selection.
- [x] Provide Blank, Midnight, Editorial, and Aurora starters as ordinary,
  parser-tested `.sld` source rather than an opaque template format.
- [x] Seed designed decks with reusable `@pushslide` layouts, a shared
  `@pushgroup` footer, stable object IDs, and `$slide_number` fields that remain
  editable through the existing Library, Objects, and Properties surfaces.
- [x] Apply starter creation as one atomic history entry; Undo returns to the
  pristine chooser without special project state.
- [x] Give untitled decks an explicit Save As prompt, append `.sld` when
  needed, and refuse existing destinations instead of silently overwriting or
  inventing a filename.

## Completed tranche: Morph and transition timeline

- [x] Present the authored BASE scene and every cumulative semantic morph state
  as responsive cards in reserved Studio chrome, never over the slide canvas.
- [x] Show each state's optional source label, automatic delay, duration, and
  easing, with the active scene synchronized across canvas and Objects.
- [x] Add, visually duplicate, rename, delete, and reorder complete state
  blocks through guarded source transactions and one-entry undo/redo.
- [x] Preserve exact state bodies, comments, BOM/line endings, and EOF layout;
  reject dynamic/global source ownership or invalid cumulative dependencies
  atomically instead of guessing.
- [x] Restore the selected BASE/state scene with timeline undo/redo and keep it
  visible while scrolling long timelines.
- [x] Verify compact, default, and large layouts headlessly and exercise a
  real four-state morph deck in the macOS Studio window.

The **Dup** operation inserts an empty following state with the selected
cumulative snapshot and copies its timing/easing. It does not replay mutations
or duplicate state-born IDs. Labels are deliberately omitted from the copy
until the author names it. BASE remains the immutable authored root: it can
seed the first state but cannot be renamed, deleted, or reordered.

## Completed tranche: Command discovery and contextual help

- [x] Add a searchable command palette, opened from a visible **Commands**
  control or <kbd>Cmd/Ctrl-K</kbd>, covering tools, document history, slides,
  selection actions, docks, composition, and morph-state operations.
- [x] Filter by title, category, description, keywords, and shortcut; support
  keyboard navigation, pointer selection, scrolling, and UTF-8-safe input.
- [x] Keep contextually unavailable actions visible with a concrete reason,
  including first/last slide, empty selection, missing morph state, empty
  clipboard, and unavailable Undo/Redo history.
- [x] Add delayed, movement-sensitive hover help across Studio chrome, with
  polished bounded cards that scale with the complete authoring shell.
- [x] Add pointer feedback for links/actions, inline text, creation tools,
  moving, resizing, and locked objects without changing source or history.
- [x] Route Save, Save Copy, Undo, and Redo through the same application-owned
  persistence/history boundaries as their keyboard equivalents.

## Completed tranche: Precision navigation and guides

- [x] Add source-neutral canvas zoom from 50% to 800%, with pointer-anchored
  wheel zoom, keyboard steps, and one-command fit/recenter.
- [x] Add wheel/trackpad, Space-drag, and middle-button canvas panning while
  preserving at least a visible slide foothold at every zoom level.
- [x] Add optional calibrated horizontal and vertical rulers whose responsive
  tick intervals remain legible throughout the zoom range.
- [x] Add distinct 5% action-safe and 10% title-safe overlays plus live
  selection dimensions and edge distances, clipped strictly to the canvas.
- [x] Expose every precision surface through the contextual command palette,
  without adding source edits, dirty state, or history entries.
- [x] Keep presentation, screenshots, PDF export, thumbnails, and Focus Canvas
  independent from editor chrome and verify compact/default layouts visually.

## Completed tranche: Large-deck performance and history confidence

- [x] Cache slide summaries, reusable-library discovery, morph summaries, and
  composition capabilities behind explicit source-revision and scene keys.
- [x] Collect all active Studio item bounds in one renderer pass instead of
  rescanning render fragments once per item.
- [x] Extend the diagnostics HUD with Studio preparation time, cache rebuild
  counters, deck size, and active item/render-fragment counts.
- [x] Add a parser-backed `--diagnostics-large-deck=COUNT` stress deck and
  validate a 160-slide document in the real macOS Studio window.
- [x] Make Undo/Redo transactional: history cursors move only after the target
  source reparses successfully, with the current source restored on failure.
- [x] Exercise structural slide/morph history and mixed direct/local/shared
  geometry batches through source patch, parse, Undo, and Redo boundaries.
- [x] Show the selected slide and total deck size beside the slide-picker
  paging controls so large decks retain a clear sense of position.

ReleaseSafe live QA on the 160-slide stress deck holds Studio preparation at
effectively 0.00 ms per steady frame, builds the complete render graph in
about 6.7 ms on the test Mac, and remains synchronized to the 60 Hz display.

## Completed tranche: Large-project navigation

- [x] Add source-neutral Find fields to Slides, Library, and Objects with
  case-insensitive title/name/type/source/status matching.
- [x] Make <kbd>Cmd/Ctrl-F</kbd> context-aware, keep independent per-panel
  queries, and use <kbd>Tab</kbd>/<kbd>Shift-Tab</kbd> to cycle Find surfaces.
- [x] Support keyboard, wheel, paging, and pointer result navigation, with
  Enter jumping to the original slide/library/object index.
- [x] Keep Background paint barriers in filtered Objects results so search
  never implies unsafe layer adjacency.
- [x] Route live slide thumbnails and all click/draw/page mappings through the
  same filtered result set; preserve the current `slide / total` footer when
  Find is inactive.
- [x] Surface all three Find commands in the contextual command palette and
  delayed hover help without adding source, dirty, or history state.
- [x] Add deterministic `--diagnostics-find-slide=QUERY` and
  `--diagnostics-window=WIDTHxHEIGHT` launch hooks for visual regression QA.

ReleaseSafe visual QA covers the live 160-slide parser-backed deck at the
monitor-aware default size and an exact 900×600 client area on macOS workspace
12. The active query, result focus, thumbnail, pager, Library, toolbar, and
morph strip remain legible and non-overlapping in both configurations.

## Completed tranche: Incremental render-graph rebuilding

- [x] Keep the renderer and image texture cache alive across parser-arena
  replacement while giving every rendered string and Crowd choice array
  explicit renderer ownership.
- [x] Fingerprint the complete parsed renderer input for each slide, excluding
  source offsets and authoring provenance that cannot change pixels.
- [x] Rebuild only semantically changed slide positions when deck structure is
  stable; changes to shared definitions naturally rebuild every parsed
  dependent slide and no unrelated one.
- [x] Retain a transactional full-deck fallback for slide-count changes and
  build every partial replacement beside the live graph before swapping any
  pointer.
- [x] Leave the complete previous graph intact on allocation/render failure,
  and retry rather than marking a failed build as current.
- [x] Report full/partial/unchanged mode, affected/total slides, and cumulative
  counters in the diagnostics HUD and log.
- [x] Add `--diagnostics-incremental-edit=N` for a deterministic real
  source/history/reparse edit after the first rendered frame.

ReleaseSafe live QA on the 160-slide stress deck measured a 6.5 ms initial
full build followed by a 0.3 ms `partial 1/160` rebuild. The edited title
appeared in the same frame sequence while the other 159 rendered-slide
pointers and the Studio shell remained stable. Headless coverage includes
local and morph edits, exact shared-definition dependency fan-out, structural
fallback, Crowd lifetime across arena replacement, unchanged pointer identity,
and induced allocation failure after one replacement has already been built.

## Completed tranche: Automated visual and performance baselines

- [x] Capture normalized compact (900×506), default (1600×900), and large
  (2560×1440) Studio frames through an application-owned screenshot path.
- [x] Cover docked Properties, the command palette, precision rulers/guides,
  the slide picker, Library, Objects, morph strip, and a 160-slide stress deck.
- [x] Record structured render, frame, cache, deck, and arena metrics beside
  every PNG, including a real `partial 1/160` source-edit rebuild.
- [x] Compare images with bounded rasterization tolerance, emit amplified diff
  artifacts, and reject rebuild-mode/count or conservative timing regressions.
- [x] Gate capture until the requested Aerospace process window is proven to
  be on workspace 12 and floating; abort rather than measure an unverified or
  tiled window, and quit every diagnostic process after capture.
- [x] Add an explicit `--no-startup-banner` launch option so unattended QA is
  independent from transient four-second startup timing.

The ReleaseSafe reference run rebuilt 24-slide graphs in roughly 0.8–0.9 ms;
the 160-slide scenario measured about 6.3 ms full and 0.3 ms partial. A second
complete capture pass matched every approved image and metric envelope.

## Completed tranche: Release and resilience confidence

- [x] Build replacement parser graphs beside the live document and adopt them
  only after parsing succeeds, preserving the current deck on syntax or
  allocation failure.
- [x] Stage replacement fonts and renderer resources before committing a file
  reload, and retain Studio history, selection, and clipboard when reload is
  rejected.
- [x] Reserve history ownership before source mutation and exercise record and
  restore allocation failures without losing redo entries or moving cursors.
- [x] Make untitled Save As clean up an unadopted reservation and verify unique
  recovery copies preserve BOM, CRLF, UTF-8, and every source byte.
- [x] Add `release-confidence` and `macos-release-qa` build gates plus a
  repeatable native checklist for focus, exact Aerospace placement,
  multi-monitor/resize/fullscreen behavior, transactional reload, recovery,
  export isolation, and shutdown hygiene.

Live macOS QA rejected a malformed external reload while retaining the active
rendered graph, then accepted the restored source and rebuilt the custom fonts,
image texture, and complete slide in the same process. A separate 1600×900
Studio capture was verified on exact workspace 12 in floating layout and exited
without leaving an application process behind.

## Completed tranche: Distribution and first-run polish

- [x] Package a reproducible, non-notarized macOS application bundle with
  version metadata, a showcase-derived icon, `.sld` document registration, a
  local identity-free ad-hoc seal, and a macOS 13 deployment target without
  replacing the ordinary CLI artifact.
- [x] Handle cold Finder launches, Open With, and live window drops through the
  same transactional loader, preserving relative deck assets and refusing to
  replace dirty or actively edited Studio source.
- [x] Keep the default build and positional CLI workflow unchanged on macOS,
  Linux, and Windows while adding release-grade `--help`, `--version`, unknown
  option handling, and a `--` positional sentinel.
- [x] Define deterministic recovery locations: beside writable named decks;
  otherwise `~/Library/Application Support/Rayslides/Recovery` for the macOS
  app, with the historical current-directory behavior retained for untitled
  terminal sessions.
- [x] Validate the packaged app from outside the checkout, including a true
  cold LaunchServices document event, custom relative fonts/images, exact
  Aerospace workspace 12 placement, and clean process shutdown.

Developer-ID signing and notarization are deliberately outside this personal
open-source project's scope. The local ad-hoc seal merely keeps the assembled
bundle internally valid; the app is a build convenience, not a replacement for
the portable command-line application or a second document format.

## Planned tranches

The next tranche will be selected after this distribution boundary has shipped
and accumulated real first-run feedback.

## Deliberate non-goals

- A second binary/project format beside `.sld`.
- A full constraint solver or browser-style layout engine in the slide syntax.
- Silent source normalization that rewrites unrelated formatting or comments.
- Pretending an unsafe template or generated-source edit is local when it is
  actually shared.
