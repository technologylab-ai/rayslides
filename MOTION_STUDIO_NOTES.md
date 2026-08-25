# Motion Studio implementation notes

Running record of judgment calls made while implementing
[`MOTION_STUDIO_ROADMAP.md`](MOTION_STUDIO_ROADMAP.md), plus what to watch
for when testing each tranche. Written for the deck author, not for the
compiler; adjust anything here and the implementation follows.

## Tranche 1 — Motion vocabulary and source primitives

Decisions:

- `delay=` is the first-step delay key (alternatives considered: `start=`,
  `first_after=`). `delay=` alone makes only the first step automatic; the
  rest wait for a click. `after=` alone keeps today's meaning for every
  step. Both together give "start delay + inter-step delay".
- `ease=` is now accepted on reveals (`@anim`/inline) and on slide
  boundaries (`@slide`, `@popslide`, `@pushslide`) with the same three
  easings as morph states. Default stays `smooth`, so existing decks render
  identically.
- `spring` easing on a `slide-*` reveal overshoots geometry briefly (same as
  morph spring); opacity is clamped to 1.
- Deck default transition = three single-value globals `@transition=`,
  `@transition_duration=`, `@transition_ease=` (matches the existing
  `@fontsize=` grammar; attribute syntax on globals is not parsed). Applied
  when a slide is emitted, so a global placed mid-deck affects the slides
  emitted after it. Put them in the preamble.
- `anim=none` / `@anim(none)` now means "no reveal" (previously it created a
  click step that appeared instantly). Needed so a `@pop` instance can cancel
  a reveal inherited from its `@push`. No deck in the repo used `none`.
- Unknown keys on `@anim` and `@state(morph)` are parser errors. Two in-repo
  offenders used `name=` instead of `label=` (a test fixture and the
  large-deck generator) and were corrected; `docs/motion.html` also showed
  `name=` in an example and was fixed.
- `order=N` is parsed and stored already; the renderer honors it in
  Tranche 7.
- Studio's Detach path now emits `delay=`, `ease=`, and `order=` so
  materialized items stay lossless.
- `Dup` of a morph state now copies every timing key verbatim (label still
  deliberately dropped). Since the parser rejects unknown state keys, nothing
  can be dropped silently anymore.
- New `source_editor` primitives write minimal source: a click-triggered
  bullet fade becomes exactly `@anim(fade) by=bullet`; default-valued
  `duration`/`ease` keys are omitted (and removed if present on the edited
  line). Unedited lines are never touched.

Watch for when testing:

- Open `testslides/studio-motion-qa.sld` and present it: slide 1 bullets on
  click; slide 2 bullets auto (0.5 s start, 0.8 s between, spring slide-in)
  and an image with a linear slide-up 0.2 s after the slide settles; slide 3
  three morph states (TAKEOVER on click, EXPLAIN auto after 1.2 s, FLOW auto
  after 0.6 s); slide 4 has no transition. The deck default is `fade 0.35 s`,
  the `content` template overrides with `slide-left 0.45 s`, slide 2
  overrides again with `fade 0.5 s spring`.
- Any older deck that used `anim=none` or `@anim(none)` now shows that item
  immediately instead of on a click.
- `zig build test`: 556 → more tests; see the tally at the end of this file.

## Tranche 2 — Motion inspector and bullet builds

Decisions:

- Motion is a third inspector tab (Objects | Properties | Motion), not a page
  inside Properties. The tab is remembered like the other two and is
  reachable through **Show Motion** in the command palette.
- Trigger strip has four cells: **None** (no reveal), **Click** (every step
  waits), **Auto** (first step after `delay`, later steps after `after`), and
  **Click>Auto** (`delay=click`: first step on click, later steps automatic).
  Choosing Auto on an item with no timing seeds `delay=0.5 after=0.8`;
  choosing Click>Auto seeds `after=0.8`. Existing values are kept.
- Choosing an effect/easing/by on an item without a reveal creates one from a
  template: fade, `by=bullet` for a bulleted text box, else `by=item`.
- Commands carry a per-target *patch* (`RevealPatch`), so multi-selection
  works even when the selected items have different reveals; the display
  shows common values or "Mixed".
- DELAY/AFTER/DUR are inline fields with the same Enter/Tab/Esc handshake as
  Properties. DELAY accepts seconds, `click`, or empty; AFTER accepts seconds
  or empty (= wait for a click); DUR accepts seconds.
- **Remove** on a direct item deletes its `@anim` decorator (or inline
  keys). On an instance that only inherits its reveal from a `@push`, the
  button reads **Cancel** and writes `anim=none`. On an instance that authors
  its own reveal locally it reads **Reset** and removes only the local
  reveal so the inherited one resurfaces.
- Reveals on shared-template members require <kbd>Alt</kbd> (or Definition
  mode); group members must be edited in Definition mode. Objects born in a
  morph state cannot own a reveal (the parser rejects it too).
- The timeline now shows BASE, one BUILD card per item with a reveal (title
  = item id or first text line; "N steps · effect · trigger"; step chips),
  then the STATE cards. Clicking a BUILD card shows the slide through that
  build's last step and selects the item; a chip narrows to one step.
  Editing in a build scene still edits the base scene. `[`/`]` and the
  toolbar `<`/`>` cycle BASE → builds → states.
- Numbered badges (`1`, `2-4`) above every item with a reveal are editor
  chrome only.
- New launch hooks: `--diagnostics-motion=ID` (select and open Motion) and
  `--diagnostics-timeline-step=N` (show the slide through step N). Visual
  baselines for the new scenarios are captured in Tranche 6 together with
  the other chrome changes.

Watch for when testing:

- Select the bullet box on slide 1 of `testslides/studio-motion-qa.sld`,
  open Motion, click **Auto**: the source gains `delay=0.5 after=0.8`; Undo
  restores it in one step.
- Type `click` into DELAY to get the "first on click, rest automatic" form.
- With several objects selected, the strips show only common values; a
  strip click patches all of them in one transaction.

## Tranche 3 — Live preview and transport

Decisions:

- The preview is a pure schedule (`src/motion_schedule.zig`) over the
  renderer's real step list: click-gated steps get a fixed 0.75 s preview gap
  so the whole slide plays through; `stateAt(t)` is a pure function of time,
  so scrubbing backwards is exact and deterministic.
- Play starts from the selected scene: BASE plays the whole slide (with the
  incoming transition when a previous slide exists), a BUILD card starts
  after that build, a STATE card starts after that state. At the end the last
  frame stays paused (so the final layout can be inspected); Stop returns to
  the selected scene; Loop restarts.
- Any source edit, Undo/Redo, slide or scene change, tool change, or canvas
  drag stops the preview. A plain click that only changes the selection does
  not.
- Transport lives in the timeline band: Play/Pause, Stop, Loop, scrubber,
  and a `time/total` readout. On narrow windows (900 px) only Play/Stop are
  shown so at least three timeline cards stay visible; the scrubber and Loop
  return on wider windows. Shift+Space toggles play/pause; Esc stops.
- Videos stay on their poster during preview (Studio never starts playback).
- New launch hooks: `--diagnostics-slide=N` (open Studio on slide N) and
  `--diagnostics-motion-preview=SECONDS` (start the preview from the current
  scene and pause it at that time).

Watch for when testing:

- Slide 3 of the QA deck: Play from BASE shows the deck-default fade, then
  TAKEOVER after the 0.75 s preview gap, EXPLAIN 1.2 s later, FLOW 0.6 s
  after that. Drag the scrubber backwards through a morph.
- Slide 2: Play shows the 0.5 s start delay, then 0.8 s between bullets, and
  the image sliding up 0.2 s after the slide settles.

## Tranche 4 — Morph timing, ghosts, and object-level state editing

Decisions:

- With a STATE card active, the Motion tab shows the State section instead
  of the Reveal section: LABEL / AFTER / DUR inline fields, a Click/Auto
  strip, the easing strip, the selected object's status line, **Reset** and
  **Exit L/R/U/D**, and a "Changes in this state" list (click a row to select
  that object).
- Choosing **Auto** on a click-gated state seeds `after=1.0`; **Click**
  removes `after=`. Emptying LABEL removes `label=` (labels must start with a
  letter or `_`).
- **Reset** deletes every `@set/@show/@hide` line for that object in the
  active state (the object inherits the previous state again). **Exit**
  appends `@hide ID x=…`/`y=…` 100 px beyond the slide edge, computed from
  the object's current size; an object needs a unique `id=` for both.
- Ghosts (toggle via **Toggle motion ghosts** in Commands; on by default):
  dashed outline of an object's previous-scene bounds, a path to its current
  center, `NEW` for objects born in the state, `EXIT` for objects hidden
  here, `SHOW` for objects shown here. Editor chrome only.
- Objects that cross-fade instead of gliding (text, media, wrapping, or
  fragment structure changed) are marked "cross-fade" in the change list and
  in the status line, using the renderer's real morph plan.
- The timeline `+` button now switches the inspector to Motion so the new
  state's timing is immediately editable.
- New launch hook: `--diagnostics-motion-state=N` (select state N with the
  Motion tab open); it composes with `--diagnostics-slide=N` and
  `--diagnostics-motion=ID`.

Watch for when testing:

- Slide 3 → EXPLAIN card → Motion: `hero`'s previous full-screen bounds show
  as a dashed ghost with a path to its new corner position; `caption` shows an
  exit path to the left; `born_here` carries a `NEW` chip.
- Select `title` on TAKEOVER, click **Reset**: both `@set title …` lines of
  that state disappear in one Undo step.

## Tranche 5 — Slide transitions

Decisions:

- The Transition section appears in the Motion tab whenever the base scene
  is shown with nothing selected; the timeline's new `IN` chip (before BASE)
  and **Edit slide transition** in Commands jump there.
- Effect grid: **Inherit**, None, Appear, Fade, Slide L/R/U/D. Inherit
  removes the slide's own `transition=`/`duration=`/`ease=` keys so the
  template or deck default applies again. Choosing an effect on a slide that
  inherits from a `@pushslide` template writes a local override on the
  `@popslide` line; hold <kbd>Alt</kbd> to change the template's line
  instead (all its instances follow).
- The provenance line reads "this slide", "from template NAME", "deck
  default", or "none". DUR/easing are only editable when the effect is not
  None.
- **Use for deck** writes the current slide's transition as the deck default
  (`@transition=`, `@transition_duration=`, `@transition_ease=` in the
  preamble); **Clear deck** removes those lines. Per-slide overrides are left
  alone; there is no "strip every override" action (Inherit does that one
  slide at a time).
- The implicit first slide of a deck without any `@slide` line cannot author
  a transition; the section says so instead of writing an invalid directive.
- Slides cards show the effect after "items · states" (e.g. "· fade").
- New launch hook: `--diagnostics-motion-transition`.

Watch for when testing:

- Slide 2 shows "this slide · fade 0.5 s spring"; click **Inherit** and the
  `@popslide content transition=fade duration=0.5 ease=spring` line loses
  those keys, so the template's `slide-left 0.45 s` applies.
- Slide 3 shows "deck default"; **Clear deck** removes the two
  `@transition*=` preamble lines and the slide falls back to "none".

## Tranche 7 — Reveal order independent of paint order

Decisions:

- `order=N` (integer, default 0) on a reveal sorts builds by `(order, source
  position)`. The renderer remaps every element's step index so partial
  reveals stay exact.
- With a BUILD card selected, the timeline `<`/`>` buttons move that build
  earlier/later. Studio assigns the *minimal* `order=` keys for the new
  sequence: the key only rises where the sequence goes against source order,
  so most decks never contain `order=` and a single swap usually writes one
  key. Keys that fall back to 0 are removed again.
- Builds owned by shared-template or group members cannot be reordered from
  an instance (same rule as editing their reveal).

Watch for when testing:

- Slide 2 of the QA deck: select the `auto_image` BUILD card and press `<`;
  the bullets' decorator gains `order=1` (the image keeps 0), and the canvas
  badges renumber to `1` for the image and `2-4` for the bullets. Press `>`
  to undo it (the key is removed again).

## Tranche 6 — Discovery, documentation, and release confidence

Decisions:

- Every Motion control has delayed hover help; the pointer becomes a hand
  over them and an I-beam over the DELAY/AFTER/DUR/LABEL fields. The status
  drawer's shortcut line now lists `[ ]` scenes, Shift-Space preview, and
  the ghosts toggle.
- Showtime gained three motion findings: `motion_long_automatic_run` (info,
  a slide that advances by itself for more than 30 s), `reveal_on_hidden_object`
  (warning, an `anim=` on a `visible=false` object), and
  `morph_state_without_changes` (info, a `@state(morph)` that changes
  nothing). None fire on the QA deck. The 30 s budget is a constant
  (`showtime.max_automatic_motion_seconds`), not yet a user setting.
- Documentation, captures, baselines, release notes, and the CLAUDE.md
  refresh were delegated to two subagents (docs / visual QA) and reviewed;
  see the roadmap checkboxes for what landed.

## Final state and decisions to review (2026-08-25)

Verification: 585/585 tests (`zig build test`), `zig build release-confidence`
green, 10/10 ReleaseSafe Studio baselines matching (4 refreshed for the new
chrome + 6 new motion scenarios), Showtime "ready" on the QA deck. Nothing is
committed; all changes are in the working tree.

Defaults and judgment calls worth a second look, in one place:

1. `delay=` / `delay=click` naming and semantics (Tranche 1).
2. `anim=none` now means "no reveal" (behavior change for any old deck that
   used it; none in the repo).
3. Unknown keys on `@anim`/`@state(morph)` are parser errors (was silent).
4. A component's `anim=` no longer leaks into later items on the slide via
   the popped context (that leak was a latent bug; fontsize/colors still
   flow as before).
5. Auto-trigger seeds: reveal `delay=0.5 after=0.8`, Click>Auto `after=0.8`,
   state `after=1.0`; preview gap for click-gated steps 0.75 s; Exit presets
   move objects 100 px beyond the edge; Showtime long-run budget 30 s.
6. Motion is a third inspector tab rather than a Properties page; the
   Transition section appears only with nothing selected in BASE.
7. Reveal `Remove` on an inherited reveal writes `anim=none` ("Cancel"); on a
   locally authored instance reveal it only removes the local part ("Reset").
8. Reorder writes minimal `order=` keys; no "strip all overrides" action for
   transitions (Inherit per slide + deck default instead).
9. Ghost outlines for text use the rendered text extent (same as Studio
   selection bounds), not the authored box.
10. Compact windows drop the scrubber/Loop from the timeline transport so
    three cards stay visible; the `Click>Auto` cell reads `Clk>Auto` there.
11. The toolbar scene label truncates to `STATE …`/`BUILD …` at 1x (it
    already did for STATE before this work).
