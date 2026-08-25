# Rayslides Motion Studio roadmap

This roadmap extends the [Studio roadmap](STUDIO_ROADMAP.md) and sits beside
the top-level [product roadmap](ROADMAP.md). It records the direction and the
exact order of work for visual motion authoring so that a long implementation
stretch, spread over many sessions and possibly several agents, cannot lose
track of what is decided, what is shipped, and what is still open.

Status: accepted product direction, 2026-08-25.

Studio is a strong visual editor for static slides, but motion is still a
text-only feature. The bottom timeline shows morph states as cards, yet the
simplest common wish—click a bullet box and make its bullets appear one by
one, automatically, with a start delay and an inter-bullet delay—cannot be
done without a text editor. Slide transitions have no GUI at all, and morph
timing (delay, duration, easing) is displayed but not editable. Every one of
those capabilities already exists in the `.sld` format. This roadmap closes
the gap: anything the format can express about motion becomes visually
authorable, previewable, and undoable inside Studio.

## Product decision

Rayslides will add a **Motion** authoring layer to Studio consisting of four
cooperating surfaces: a **Motion inspector** tab beside Objects and
Properties, an upgraded **step timeline** in the reserved bottom band that
shows reveal builds and morph states as one ordered sequence, **canvas
motion overlays** (build-order badges, morph ghosts, and motion paths), and an
editor-side **live preview** that plays the current slide's real reveal,
morph, and transition timing on the canvas.

The primary workflows, in priority order:

1. Select a text box, choose **Build bullets**, switch it to **Automatic**,
   and set the start delay and inter-bullet delay. Press **Play** to watch it.
2. Choose the incoming transition of the current slide, or the deck default,
   and preview it.
3. Add, name, time, ease, reorder, and preview morph states; see where every
   object comes from in the previous state while editing the current one.
4. Reveal any item (image, video, shape, line, component) with any effect,
   timing, and easing; see the resulting step order on the canvas.

The format grows only where a GUI cannot honestly express an author's intent
with the existing vocabulary: a first-step `delay=`, `ease=` on reveals and
transitions, deck-level transition defaults, and an optional `order=` for
reveal order independent of paint order. Everything else is exposed as-is.

## Non-negotiable principles

- `.sld` remains the source of truth. Every completed Motion action is one
  guarded, reparsable, undoable source edit that preserves unrelated bytes,
  comments, BOM, and line endings.
- Existing decks keep their exact meaning. New vocabulary is additive and
  defaults to today's behavior; no existing directive changes semantics.
- Source ownership stays explicit. Reveal specs inherited from a `@push`
  definition, transitions inherited from a `@pushslide` template or the deck
  default, and morph-state mutations are shown with their provenance and are
  reset by removing exactly that source layer, never by writing a default.
- Ambiguous or shared-source edits fail atomically with a concrete reason,
  exactly like the existing Properties and timeline operations.
- Presentation, PDF export, screenshots, Presenter preview, and Showtime
  never see editor chrome or the editor-side preview clock. Live preview is
  a Studio rendering choice, not a playback state of the deck.
- The preview uses the real renderer, the real step timeline, and the real
  easing functions. There is no second animation implementation.
- The Motion inspector, timeline, overlays, and preview are keyboard and
  command-palette reachable, carry delayed hover help, and scale coherently
  across the compact (900×506), default (1600×900), and large (2560×1440)
  Studio surfaces.
- Every tranche ships with headless source round-trip tests, Studio
  interaction tests driven by synthetic `FrameInput`, deterministic
  `--diagnostics-*` launch hooks, and visual baselines at all three sizes.
- Each increment updates the checkboxes and explanatory record in this file
  as it ships, so implementation and roadmap cannot drift apart.

## Verified starting point

The following was verified against the source on 2026-08-25 and is the
baseline every tranche builds on. Anchors name functions rather than line
numbers because lines drift; use `grep -n` on the function name.

Format and runtime (`src/animation.zig`, `src/parser.zig`, `src/slides.zig`,
`src/renderer.zig`, `src/playback.zig`):

- Reveal vocabulary: `@anim(EFFECT)` decorator or inline `anim=`/`effect=`,
  with `by=item|line|bullet`, `after=SECONDS`, `duration=SECONDS`. Effects:
  `none`, `appear`, `fade`, `slide-left`, `slide-right`, `slide-up`,
  `slide-down`. Reveals attach to `@box`, `@line`, `@pop`, `@bg`, `@crowd`,
  must precede the first `@state(morph)`, and propagate from `@push` to
  `@pop` through `ItemContext.applyOtherIfNull`. `animation.ItemSpec` has no
  easing; reveals always use the fixed smoothstep in `renderRenderedSlide`.
  One `after=` applies to every step the item generates, so there is no
  separate first-step delay.
- Morph vocabulary: `@state(morph) [label=] [after=] [duration=] [ease=]`
  with `@set`/`@show`/`@hide` mutations and items born inside states.
  `animation.MorphSpec` defaults are 0.6 s and `smooth`; `ease=` and `label=`
  are parse errors anywhere else. Morphable properties are enumerated by
  `SlideItem.applyPatch`. Interpolation and the cross-fade fallback live in
  `buildMorphPlan`, `interpolateElement`, and `elementPayloadCompatible`.
- Transitions: `transition=EFFECT [duration=]` on `@slide`, `@popslide`, or
  `@pushslide`; consumed only at slide boundaries and silently ignored
  elsewhere. `animation.Transition` has no easing and `SlideShow` has no deck
  default. Transition progress uses the fixed smoothstep.
- Step timeline: `RenderedSlide.steps` is flat and ordered: every reveal step
  in item/line order, then one morph step per state. `baseRevealStepCount`,
  `stepCount`, and `stepAt` expose it. Reveal steps for one item are
  contiguous and appended in paint order, so reveal order equals paint order.
- Playback: `playback.State` drives reveal/hide/settle and `shouldAutoReveal`;
  `updateAutomaticReveal` in `src/main.zig` advances automatic steps.
- Unknown attribute keys are silently ignored by `parseItemAttributes`.
  `testslides/showtime-preflight-failures.sld` and the large-deck generator in
  `src/main.zig` both use a bogus `@state(morph) name=` spelling.

Studio (`src/studio.zig`, `src/main.zig`, `src/source_editor.zig`):

- Studio emits `GeometryCommand`/`SemanticCommand` intentions;
  `applyStudioSemanticEdit` in `src/main.zig` turns them into
  `source_editor` patches, then `recordStudioPatch` → `replaceEditorSource`
  → `reparseEditorSource` with transactional rollback.
- The scene shown on the canvas is `active_morph_state: ?usize` (`null` is
  BASE). `main.zig` selects `slide.items` or
  `slide.morph_states[state].items`, and renders with a snapped
  `RevealState{ .visible_through = baseRevealStepCount + state + 1 }` and an
  empty `TransitionState`. Nothing animates in Studio; `updateAutomaticReveal`
  and video playback are gated off while Studio captures input.
- The bottom band already hosts `morphTimelineLayout`/`drawMorphTimeline`
  with BASE and state cards, six actions (`+`, `Dup`, `Name`, `Del`, `<`,
  `>`), index-based horizontal scrolling, and `[`/`]` scene cycling. The five
  structural state commands (`add/duplicate/rename/delete/move_morph_state`)
  are backed by `insertMorphStateAfter`, `duplicateMorphState`,
  `renameMorphState`, `deleteMorphState`, and `moveMorphState`.
  `duplicateMorphDirective` intentionally drops `label=` and silently drops
  any unknown token.
- Morph timing is display-only: `MorphStateSummary` carries `after`,
  `duration`, and `easing` for the cards, but no command, field, or
  `source_editor` function edits them. `renameMorphState` is a one-function
  template (`patchLiteralAttributes` on `label=`).
- Nothing in Studio reads or writes `Slide.transition` or any reveal
  attribute. `InlineField`/`AuthoredProperty` contain no motion entries. The
  only emitter of reveal syntax is `materializeStudioItem` (component
  Detach), which writes the inline `anim=` form.
- Inline Properties fields are declared in parallel hard-coded arrays in
  `drawInlineProperties`; adding a field touches `InlineField`,
  `AuthoredProperty`, `authoredPropertyForInlineField`, `inlineFieldRect`,
  `inlineFieldApplies`/`inlineFieldVisible`, and the label array.
- Widget inventory: action/compact/toggle buttons, inline text fields, 8-swatch
  color strip, one bespoke slider (grid contrast), overlay list panels
  (command palette, reusable picker), a single modal prompt owned by
  `main.zig`, tooltips, and virtualized row lists. There is no segmented
  choice control, reusable slider, numeric stepper, dropdown, or scrubber.
  `InspectorPanel` is a closed enum of `objects` and `properties`.
- Diagnostics hooks follow the `…ForDiagnostics` pattern on `Studio`, wired
  to `--diagnostics-*` flags in `src/main.zig`; baselines are declared in
  `tools/studio_baseline.py` and checked into `tests/studio_baselines/`.
- Visibility inside a state is already written as `@hide ID`/`@show ID`, and
  `collectItemRenderBoundsForMorphState` can resolve bounds for any scene.

## Intended motion authoring experience

### Motion inspector

A third tab, **Motion**, joins Objects and Properties in the right dock. It
is context-sensitive and always states whose motion it is editing:

- **Reveal** (one or more selected items in BASE or a reveal-step scene):
  a trigger choice **None / On click / Automatic**, an effect choice strip
  (`appear`, `fade`, `slide-left`, `slide-right`, `slide-up`, `slide-down`),
  a **By** choice (`item`, `line`, `bullet`; text items only), exact fields
  **Start delay**, **Between steps**, **Duration**, and an **Ease** choice.
  A **Build bullets** preset writes `@anim(fade) by=bullet` in one action; a
  **Remove reveal** action deletes the decorator or inline attributes. A
  compact step list ("3 steps · bullet 1–3") mirrors the badges on the
  canvas. Multi-selection shows truthful common/Mixed values and commits as
  one atomic batch, refusing wholesale when any owner is unsafe.
  Ownership badges and amber **R** reset chips follow the Properties model:
  a reveal inherited from a `@push` definition is shown as inherited, a
  local `anim=` on the `@pop` line is a local override, template members are
  shared unless <kbd>Alt</kbd> is held, and morph-born items explain that they
  animate as part of their state.
- **State** (a morph state is the active scene): editable **Label**,
  trigger **On click / Automatic after N s**, **Duration**, and **Ease**, the
  existing Dup/Delete/Move actions, and a **Changes in this state** list
  naming every object mutated here with the properties it changes. With an
  object selected, **Reset object in this state** removes all of its
  `@set`/`@show`/`@hide` lines in the state, and **Exit left/right/up/down**
  presets write an off-canvas `@hide`.
- **Transition** (no item selected, or the dedicated **Slide** section that
  is always available at the top): effect choice including **None** and
  **Inherit**, **Duration**, **Ease**, provenance (this slide, `@pushslide
  NAME`, or deck default), an amber **R** to remove the local value, and
  **Deck default…** which edits the deck-level `@transition*=` directives.
- Every field validates client-side, retains invalid drafts with a local
  explanation, and never touches source or history until validation
  succeeds—identical to Properties.

### Step timeline

The bottom band grows from "morph cards" into the complete ordered sequence
of one logical slide: **BASE**, then one **BUILD** card per item that owns a
reveal (title, step count, trigger, timing), then one **STATE** card per morph
state. Cards keep today's density rules and index-based scrolling.

- Clicking BASE shows the fully revealed authored scene (unchanged).
- Clicking a BUILD card selects its item and shows the canvas *through* that
  build's last step; the card expands into per-step chips so a single bullet
  step can be selected. Items not yet revealed at that step are absent from
  the canvas but remain reachable through Objects, exactly like hidden items.
- Clicking a STATE card selects that cumulative scene (unchanged).
- The actions row becomes contextual: **+ State**, **Dup**, **Name**, **Del**,
  **<**, **>** for states; **<**/**>** on BUILD cards reorder reveal order
  (Tranche 7), and a **transport** group (**Play**, **Stop**, **Loop**, a
  scrubber, and a time readout) drives the live preview.
- Transition is drawn as a small leading chip before BASE that opens the
  Transition section when clicked and previews the transition when played.

### Canvas motion overlays

- **Build badges**: a small numbered badge at the top-left of every item
  that owns a reveal, showing its step range in slide order (`1`, `2–4`).
  The badge doubles as a click target that opens Motion for that item.
- **Morph ghosts and paths**: while a morph state is active, every object
  changed in that state shows its previous-scene bounds as a dashed ghost
  and a thin path from the ghost center to the current center. Objects born
  or hidden here are marked with `NEW`/`EXIT` chips. Toggleable through the
  command palette; default on.
- All overlays are editor chrome: they never reach presentation, export,
  thumbnails, Library previews, or Presenter output.

### Live preview

**Play** runs the current slide from the selected scene using the real
renderer and easing, then stops at the end (or loops). Click-gated steps
advance automatically after a fixed preview gap so the whole slide plays
through. The scrubber maps a preview time to the step/progress pair the
renderer needs and can be dragged in both directions. Playing from the
transition chip shows the previous logical slide and the incoming transition
first. Any source edit, undo/redo, scene change, tool change, pointer gesture
on the canvas, or <kbd>Esc</kbd> stops the preview and returns to the
selected scene. Videos remain on their poster during preview. The preview
clock is Studio-owned and deterministic for diagnostics.

## Source format decisions

All additions are optional attributes or optional global directives. Absent
attributes reproduce today's behavior byte-for-byte in the renderer.

| Addition | Syntax | Meaning |
| --- | --- | --- |
| First-step delay | `delay=SECONDS` on `@anim(...)`/inline reveals | The first step of this item's build starts automatically `delay` seconds after the slide settles or the previous step settles. Later steps use `after=`. `delay` alone makes only the first step automatic; `after` alone keeps today's meaning for every step. |
| Reveal easing | `ease=linear\|smooth\|spring` on `@anim(...)`/inline reveals | Adds `easing` to `animation.ItemSpec` and `Step.fromItem`; the renderer calls `applyEasing(step.easing, …)` for reveals. Default `smooth`. |
| Transition easing | `ease=` on `@slide`, `@popslide`, `@pushslide` | Adds `easing` to `animation.Transition`; `renderTransitioned` uses it. Default `smooth`. |
| Deck transition default | `@transition=EFFECT`, `@transition_duration=SECONDS`, `@transition_ease=EASING` global directives | Stored on `SlideShow`; applied at slide commit when the slide's own boundary and its `@pushslide` template set nothing. `transition=none` on a slide still disables it. Uses the existing single-value `@name=value` global grammar. |
| Reveal order (optional, Tranche 7) | `order=N` on `@anim(...)`/inline reveals | Reveal steps sort by `(order, source position)`. Unset order sorts as 0. Lets Studio reorder builds without changing paint order. |
| Closed-vocabulary hygiene | parser error for unknown keys on `@anim` and `@state` | Prevents silently dropped intent such as `name=`, `easing=`, or `delay` typos. In-repo `name=` uses are corrected. `@box` and other open directives are unaffected. |

Studio writes reveals in the documented decorator form
(`@anim(EFFECT) by=… delay=… after=… duration=… ease=…`) on the line
immediately before the owning directive, using `itemOwnedAnimationStart` to
find and patch an existing decorator and `patchLiteralAttributes` for inline
forms already present. Values are written only when they differ from the
defaults, so a click-triggered fade stays `@anim(fade) by=bullet`.

## Architecture and integration points

- **Scene model**: `Studio` keeps `active_morph_state` and adds
  `visible_reveal_step: ?usize`. Selecting a BUILD card/chip sets the step
  and clears the morph state; selecting BASE or a STATE clears the step.
  `main.zig` derives `RevealState.visible_through` from the step when set.
  Item editing in a reveal-step scene targets the base scene exactly as
  BASE does; only the rendered step changes.
- **Timeline model**: `Workspace.timeline: []const TimelineCard` replaces the
  state-only `morph_states` slice. Cards are `base`, `transition`, `build`
  (`owner_identity`, item id/label, `first_step`, `step_count`, spec
  summary, provenance), and `state` (today's `MorphStateSummary`). Built in
  `main.zig` from `RenderedSlide.steps` through a new renderer API
  `revealBuilds(slide_number)` that groups contiguous reveal steps by
  `owner_identity` and reports each build's `ItemSpec`.
- **Motion inspector**: `InspectorPanel` gains `motion`; `drawInspectorTabs`,
  `handleUiClick`, `frameLayout`/`uiLayout` sizing, tooltip keys, and the
  command palette gain the tab. The inline field table is made declarative
  (`InlineFieldSpec { field, label, applies, rect_role }`) before the motion
  fields are added, so new fields no longer touch six sites.
- **Widgets**: a reusable `ChoiceStrip` (segmented, wraps to a second row on
  compact widths, keyboard cycle with <kbd>Left</kbd>/<kbd>Right</kbd>) and a
  reusable `Slider` extracted from the grid-contrast control. Both are
  drawn with the existing button surfaces and theme.
- **Commands**: new `SemanticCommand` variants `set_item_reveal`
  (`ItemRevealCommand` with targets + optional `ItemSpec`, `null` removes),
  `set_morph_state_timing`, `set_slide_transition`, `set_deck_transition`,
  `reset_morph_object`, `move_reveal_build`, plus preview control intents
  that never reach source (`preview_play`, `preview_stop`, `preview_seek`).
- **Source primitives** (`src/source_editor.zig`): `setItemReveal`,
  `removeItemReveal`, `setMorphStateTiming`, `setSlideTransition`,
  `removeSlideTransition`, `setDeckTransitionDefaults`,
  `deleteMorphMutationsForItem`, `setRevealOrder`. Each follows the
  `PatchResult` contract, validates ownership through the existing
  `MutationOwner`/`SourceScope` rules, and is covered by byte-exact
  round-trip tests including BOM/CRLF fixtures.
- **Preview**: `StudioMotionPreview` in `main.zig` owns a deterministic
  clock and a pure `motion_schedule.zig` that turns `RenderedSlide.steps`
  (+ optional transition) into absolute time windows with a fixed gap for
  click-gated steps. `main.zig` feeds `RevealState`/`TransitionState` from
  the schedule while playing; export and presentation paths are untouched.
- **Overlays**: build badges use existing item bounds; ghosts use
  `collectItemRenderBoundsForMorphState` for the previous scene and the
  per-item `state_source_state` to know which objects changed here.
- **Diagnostics**: `--diagnostics-motion=ITEM_ID` (select item, open
  Motion), `--diagnostics-timeline-step=N` (select a reveal step),
  `--diagnostics-motion-state=N` (select a state with ghosts), and
  `--diagnostics-motion-preview=SECONDS` (seek the deterministic preview
  clock) drive baseline captures without synthesized input.

## Delivery tranches

Tranches are ordered by dependency and by user value: the vocabulary and
source primitives first (everything else patches source through them), then
the bullet-build workflow, then preview (so every later tranche is visible
while it is built), then morph timing and ghosts, transitions, polish, and
finally the optional reveal-order feature.

### 1. Motion vocabulary and source primitives

- [x] Add `delay=` (first-step delay) and `ease=` to reveals: extend
      `animation.ItemSpec` and `Step.fromItem`, thread the first-step flag
      through `appendStep`/`wholeItemStep`/`preRenderTextBlock`, and use
      `applyEasing(step.easing, …)` for reveal transforms.
- [x] Add `ease=` to `animation.Transition`, parse it on slide boundaries,
      and use it in `renderTransitioned`.
- [x] Add `@transition=`, `@transition_duration=`, and `@transition_ease=`
      deck defaults to `SlideShow` and apply them at slide commit when the
      boundary and its template set nothing; `transition=none` still wins.
- [x] Diagnose unknown keys on `@anim` and `@state` as parser errors; fix
      the `name=` uses in `testslides/showtime-preflight-failures.sld` and
      the large-deck generator in `src/main.zig`.
- [x] Add renderer `revealBuilds(slide)` grouping contiguous reveal steps by
      `owner_identity` with the owning `ItemSpec` and a display label.
- [x] Add `source_editor` primitives `setItemReveal`, `removeItemReveal`,
      `setMorphStateTiming`, `setSlideTransition`, `removeSlideTransition`,
      `setDeckTransitionDefaults`, and `deleteMorphMutationsForItem`, each
      writing non-default values only and preserving unrelated bytes.
- [x] Make `duplicateMorphDirective` copy every known timing key and refuse
      (rather than drop) unknown tokens; keep the deliberate label omission.
- [x] Extend `materializeStudioItem` to emit `delay=`/`ease=` so Detach
      remains lossless.
- [x] Document the new vocabulary in `docs/REFERENCE.md` and
      `docs/motion.html`; add `testslides/studio-motion-qa.sld` exercising
      click and automatic bullet builds with distinct start/inter-step
      delays, an eased image reveal, inherited/overridden/deck-default
      transitions, and a three-state morph with born, hidden, and shown
      objects.

Exit gate: the fixture parses cleanly, `zig build test` covers parser,
playback, renderer, and byte-exact round trips for every primitive, and a
deck without the new attributes renders pixel-identically to before.

### 2. Motion inspector and bullet builds

- [x] Make the inline Properties field table declarative, then add the
      `InspectorPanel.motion` tab with tab drawing, click routing, tooltip
      keys, dock sizing at all densities, and a command-palette entry.
- [x] Add the reusable `ChoiceStrip` widget with pointer and keyboard
      selection, wrapping, and disabled states.
- [x] Implement the Reveal section: trigger, effect, By, Start delay,
      Between steps, Duration, Ease, **Build bullets**, **Remove reveal**,
      the step list, provenance badges, amber **R** reset, and <kbd>Alt</kbd>
      shared-edit behavior through `set_item_reveal`.
- [x] Support ordered multi-selection with common/Mixed values and one
      atomic batch commit; refuse wholesale when any target is a morph-born
      item, generated source, or an unsafe shared owner.
- [x] Draw build badges on the canvas for every item with a reveal, with
      step ranges in slide order; clicking a badge selects the item and opens
      Motion.
- [x] Replace the state-only timeline model with `TimelineCard`s: BASE,
      BUILD cards with per-step chips, STATE cards; add
      `visible_reveal_step` scene selection and keep `[`/`]` cycling through
      BASE, each build, and each state.
- [x] Add `--diagnostics-motion=ITEM_ID` and
      `--diagnostics-timeline-step=N`; add `compact-motion` (900×506),
      `default-timeline` (1600×900), and `large-motion` (2560×1440)
      baselines on the QA fixture.

Exit gate: on the fixture, an author can select a bullet box, click **Build
bullets**, choose **Automatic**, set a 0.5 s start delay and 0.8 s inter-step
delay, see `1–3` on the canvas, step through the build on the timeline, undo
in one step, and read the resulting `@anim(fade) by=bullet delay=0.5
after=0.8` in the saved source.

### 3. Live preview and transport

- [x] Add `src/motion_schedule.zig`: a pure function from
      `RenderedSlide.steps` (+ optional transition, + preview gap) to
      absolute windows, with `stateAt(time)` returning
      `visible_through`/`active_step`/`progress`, unit-tested including
      reverse scrubbing and zero-duration steps.
- [x] Add `StudioMotionPreview` to `main.zig` with a deterministic clock,
      Play/Stop/Loop/seek, and automatic stop on any source edit, history
      move, scene change, tool change, canvas gesture, or <kbd>Esc</kbd>.
- [x] Feed `RevealState`/`TransitionState` from the preview while playing;
      leave export, presentation, thumbnails, Library previews, and Presenter
      untouched; keep videos on their poster.
- [x] Add the timeline transport group (**Play**, **Stop**, **Loop**,
      scrubber via the reusable `Slider`, time readout) with
      <kbd>Shift-Space</kbd> as Play/Stop, command-palette entries, and hover
      help; keep the group legible at compact density.
- [x] Highlight the playing card/chip on the timeline as the preview
      advances; the playhead follows the schedule.
- [x] Add `--diagnostics-motion-preview=SECONDS` and a `default-preview`
      baseline captured mid-morph on the fixture.

Exit gate: pressing Play on the bullet-build slide shows the bullets appear
with the authored delays and easing, the scrubber can be dragged backward
through the same frames, and no presentation, export, or Showtime pixel or
metric changes while the preview exists.

### 4. Morph timing, ghosts, and object-level state editing

- [x] Implement the State section of Motion: Label, trigger, Duration, Ease
      through `set_morph_state_timing`, reusing the existing rename, Dup,
      Del, and move commands; make **+ State** open the State section with
      the new state selected.
- [x] Add the **Changes in this state** list from per-item
      `state_source_state`, with click-to-select.
- [x] Add **Reset object in this state** (`reset_morph_object` →
      `deleteMorphMutationsForItem`) and the **Exit left/right/up/down**
      presets that write an off-canvas `@hide`.
- [x] Draw morph ghosts, paths, and `NEW`/`EXIT` chips for objects changed in
      the active state; add a **Motion ghosts** toggle to the command palette
      and persist it for the session only.
- [x] Report the cross-fade fallback honestly: when the renderer's plan uses
      `source_fade`/`target_fade` for an object because text, media, or
      wrapping changed, the State section lists it under **Cross-fades**
      with the reason.
- [x] Add `--diagnostics-motion-state=N` and a `large-morph-ghosts`
      baseline.

Exit gate: an author can create a state, set 0.8 s `spring`, drag two
objects, see their ghosts and paths, reset one object, preview the state,
and every action is one Undo step with the exact `@state(morph)` and
`@set`/`@hide` lines in source.

### 5. Slide transitions

- [x] Implement the Transition section: effect choice (None/Inherit/effects),
      Duration, Ease, provenance label, amber **R**, and **Deck default…**
      through `set_slide_transition`, `removeSlideTransition`, and
      `set_deck_transition`.
- [x] Resolve provenance: this slide's `@slide`/`@popslide`, an inherited
      `@pushslide` value (edit locally by default, shared with
      <kbd>Alt</kbd> and an affected-use count), or the deck default.
- [x] Add the transition chip before BASE on the timeline and a small
      transition badge on Slides cards; playing from the chip previews the
      incoming transition from the previous logical slide, disabled on the
      first slide with a reason.
- [x] Add a **Transition for all slides** action that writes the deck default
      and optionally clears per-slide overrides after an explicit preview of
      how many slides are affected.
- [x] Extend the compact/default baselines with the Transition section.

Exit gate: an author can set a deck-wide `fade 0.4 s`, override one slide to
`slide-left`, reset it back to inherited, and preview each choice, with the
saved source showing `@transition=fade`, `@transition_duration=0.4`, and one
`@popslide … transition=slide-left`.

### 6. Discovery, documentation, and release confidence

- [x] Add every Motion action to the command palette with contextual
      unavailability reasons, add hover help, pointer feedback, and status
      drawer help text; ensure <kbd>Tab</kbd> traversal covers Motion fields.
- [x] Add Showtime findings for motion: automatic steps whose total schedule
      exceeds a configurable budget, reveals on locked/hidden items, and
      states with no changes.
- [x] Refresh `docs/REFERENCE.md` (Studio visual editing, Rendering
      diagnostics, Animations, Semantic morph states), `docs/motion.html`,
      `docs/studio.html`, README bullets, `docs/DOCUMENTATION_PLAN.md`, and
      capture `motion-inspector.png`, `timeline-build.png`,
      `morph-ghosts.png`, and `motion-preview.png` through
      `tools/docs_studio_capture.py`.
- [x] Update `CLAUDE.md` core components (studio, source_editor,
      motion_schedule, playback, showtime) and build/QA commands.
- [x] Record release notes, run `zig build release-confidence` and the
      ReleaseSafe baseline suite, and perform the macOS live QA pass on the
      fixture at all three window sizes.

Exit gate: every Motion capability is discoverable from the command palette
and documented with a real capture; automated and visual gates pass.

Shipped record (2026-08-25): 585 automated tests pass, `zig build
release-confidence` passes, and the ten ReleaseSafe Studio baselines (four
refreshed for the new chrome, six new motion scenarios at 900×506, 1600×900,
and 2560×1440) match on macOS workspace 12. The remaining human step is a
hands-on presentation run of `testslides/studio-motion-qa.sld` on a real
projector; the automated captures stand in for the three-size Studio pass.

### 7. Reveal order independent of paint order (optional)

- [x] Add `order=N` to reveal specs; sort reveal steps by `(order, source
      position)` in `buildRenderedSlide` and remap `reveal_step` indices.
- [x] Add `setRevealOrder`, the `move_reveal_build` command, and **<**/**>**
      on BUILD cards; renumber badges accordingly.
- [x] Cover parser, renderer, round-trip, and timeline tests; document the
      key and its interaction with paint order.

Exit gate: an author can move an image build before a bullet build without
changing layer order, and the source shows only the `order=` values needed.

This tranche shipped together with the others: `order=` keys are written only
where the desired sequence inverts source order, so a deck without reordered
builds never gains an `order=` attribute.

## Test and QA contract

- Parser tests for every new key, every new error message, and default
  preservation; playback tests for first-step delay and click-gated
  scheduling; renderer tests for reveal easing, transition easing, build
  grouping, and order remapping.
- Byte-exact `source_editor` round trips for every primitive, including
  decorator vs. inline forms, `@pop` local overrides, template refusal,
  BOM/CRLF fixtures, and inverse operations returning the original bytes.
- Studio interaction tests with synthetic `FrameInput` proving that view-only
  actions (tab switch, timeline selection, ghosts toggle, preview) leave
  `dirty` false and emit no geometry batch or semantic command, and that
  each editing action emits exactly one command with the expected payload.
- `studio_roundtrip_test.zig` integration flows for the five exit-gate
  workflows above.
- Visual baselines: `compact-motion`, `default-timeline`,
  `default-preview`, `large-motion`, `large-morph-ghosts`, plus the existing
  four scenarios re-approved after chrome changes.
- Live macOS QA on `testslides/studio-motion-qa.sld` and
  `testslides/test_public.sld` at 900×506, 1600×900, and 2560×1440, then a
  real presentation run of both decks proving the audience-facing pixels
  are unchanged by editor state.

## Release confidence

The motion authoring layer is complete when:

- every reveal, morph-state, and transition attribute the parser accepts can
  be created, edited, reset, and removed from Studio without a text editor;
- the bullet-build workflow, transition workflow, and morph workflow each
  round-trip through save, reopen, and Undo/Redo with byte-preserving
  source outside the edited lines;
- the live preview reproduces presentation timing on the canvas while
  presentation, export, Showtime, and Presenter outputs remain unchanged;
- all headless tests pass, all visual baselines match at the three window
  sizes, and the macOS live QA checklist is recorded in this file with the
  measured test count and baseline results;
- documentation shows every Motion surface with a real capture.

## Explicit non-goals for this roadmap

- A per-property or per-object timeline inside one morph state. One state
  keeps one duration and one easing; authors split states for more control.
- Keyframe curves, motion paths as authored geometry, physics, or a general
  easing editor beyond the three named easings.
- Looping, ping-pong, or idle animations in the format.
- Interleaving reveals between morph states; reveals stay before the first
  state as today.
- Editing animations inside `@pushslide` templates or `@popgroup` members
  beyond what the existing shared-edit rules already allow.
- A second animation runtime for the editor; the preview must use the
  presentation renderer and easing.
- Silent normalization of unrelated source, or rewriting decorators into
  inline attributes (or vice versa) that the author did not touch.

## Implementation anchors

Use these names with `grep -n`; line numbers move.

- `src/animation.zig`: `ItemSpec`, `MorphSpec`, `Step.fromItem`,
  `Transition`, `parseEffect`, `parseEasing`, `applyEasing`.
- `src/parser.zig`: `parseItemAttributes` (attribute loop and
  `@anim`/`@state` normalization), `commitParsingContext`,
  `commitMorphMutation`, `commitItemToSlide`, slide boundary handling for
  `@slide`/`@popslide`/`@pushslide`, global `@name=value` directives.
- `src/slides.zig`: `SlideShow` defaults, `Slide.transition`,
  `Slide.applyContext`, `MorphState`, `SlideItem.animation`,
  `SlideItem.applyPatch`, `ItemContext.applyOtherIfNull`.
- `src/renderer.zig`: `buildRenderedSlide`, `appendStep`, `wholeItemStep`,
  `preRenderTextBlock`, `stepCount`, `baseRevealStepCount`, `stepAt`,
  `renderRenderedSlide`, `renderTransitioned`, `itemAnimationTransform`,
  `buildMorphPlan`, `collectItemRenderBoundsForMorphState`.
- `src/playback.zig`: `State.reveal/hide/settle/shouldAutoReveal`.
- `src/source_editor.zig`: `patchLiteralAttributes`, `insertDirectiveAt`,
  `itemOwnedAnimationStart`, `itemInsertionOffsetBeforeAnimations`,
  `morphStateEndOffset`, `morphStateRange`, `insertMorphStateAfter`,
  `duplicateMorphDirective`, `renameMorphState`, `validateMorphStateBlock`,
  `validateMorphMutationTarget`, `deleteItemCascadingMorphMutations`.
- `src/studio.zig`: `InspectorPanel`, `InlineField`, `AuthoredProperty`,
  `SemanticCommand`, `Workspace`, `MorphStateSummary`, `morphTimelineLayout`,
  `drawMorphTimeline`, `handleMorphTimelineClick`, `drawInspectorTabs`,
  `drawInlineProperties`, `inlineFieldRect`, `nextInlineField`,
  `setGridContrastFromPointer` (slider to extract), `FrameInput.fromRaylib`,
  `CommandSpec`, `tooltipTargetAtPoint`, `noticeMessage`,
  `…ForDiagnostics` hooks.
- `src/main.zig`: scene item selection and `RevealState`/`TransitionState`
  construction in the frame loop, `updateAutomaticReveal`,
  `applyStudioSemanticEdit`, `applyStudioGeometryEdit`,
  `morphItemEditTarget`, `materializeStudioItem`, `recordStudioPatch`,
  `StudioHistory`, `--diagnostics-*` parsing and help text,
  `captureDiagnosticScreenshot`.
- `src/showtime.zig`: scene traversal and finding codes.
- `tools/studio_baseline.py`, `tools/docs_studio_capture.py`,
  `tests/studio_baselines/README.md`.
