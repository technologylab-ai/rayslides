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
  font, while presentation and export retain the full slide viewport.
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

## Planned tranches

### New-deck experience

- Create a deck from an empty document entirely in Studio.
- Build and manage themes, slide templates, title/page-number roles, and common
  reusable blocks in the same source file.
- Provide useful starter layouts without hiding their generated `.sld` syntax.

### Morph and transition timeline

- Present base plus semantic morph states as an explicit timeline.
- Add, duplicate, rename, reorder, and preview states visually.
- Make state inheritance, local overrides, and transition ownership visible.

### Precision and polish

- Keyboard-accessible command discovery, contextual help, and improved cursor
  feedback.
- Scale the complete Studio chrome coherently for native 4K, high-DPI, and
  projector use—dock widths, rows, hit targets, and typography together rather
  than enlarging text inside fixed panels.
- Optional rulers, measurements, safe-area guides, zoom, and pan.
- Performance work for large decks and richer integration-level history tests.

## Deliberate non-goals

- A second binary/project format beside `.sld`.
- A full constraint solver or browser-style layout engine in the slide syntax.
- Silent source normalization that rewrites unrelated formatting or comments.
- Pretending an unsafe template or generated-source edit is local when it is
  actually shared.
