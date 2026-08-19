# rayslides -- [slides](https://github.com/renerocksai/slides) ported to raylib

See [here](https://github.com/renerocksai/slides) for the original slides project.

This port is minimalistic, and I wrote it to be able to edit, present, and PDF-export slides on a Mac.

Due to the new [raylib](https://github.com/raysan5/raylib) dep, builds should work on all 3 major platforms now.

![screenshot](rayslides.jpg)

Missing but maybe coming soon:

- SDF-based font scaling

Missing but probably not coming soon:

- PPTX Export

## Presentation and Slide Navigation

See the next section for keyboard shortcuts for slideshow control and slide navigation. In addition to using the keyboard, you can also use a "clicker" / "presenter" device.

## Keyboard Shortcuts

| Shortcut | Description |
| -------- | ----------- |
| <kbd>Q</kbd> | Quit |
| <kbd>ESC</kbd> | Quit |
| <kbd>S</kbd> | Screen-Shot current slide  to PNG |
| <kbd>SHIFT</kbd> + <kbd>S</kbd> | Screen-Shot and export slideshow to PDF |
| <kbd>F</kbd> | Toggle fullscreen |
| <kbd>L</kbd> | Toggle laserpointer |
| <kbd>SHIFT</kbd> + <kbd>L</kbd> | Iterate laserpointer sizes |
| <kbd>C</kbd> | Clear laserpointer drawing |
| <kbd>B</kbd> | Toggle Beast Mode* |
| <kbd><-</kbd> | Hide the previous animation step or goto the previous slide |
| <kbd>PgUp</kbd> | Hide the previous animation step or goto the previous slide |
| <kbd>Backspace</kbd> | Hide the previous animation step or goto the previous slide |
| <kbd>-></kbd> | Reveal the next animation step or goto the next slide |
| <kbd>PgDown</kbd> | Reveal the next animation step or goto the next slide |
| <kbd>Space</kbd> | Reveal the next animation step or goto the next slide |
| Left click | Reveal the next animation step or goto the next slide |
| <kbd>1</kbd> | Goto first slide |
| <kbd>0</kbd> | Goto last slide |
| <kbd>G</kbd> | Goto first slide |
| <kbd>Shift</kbd> + <kbd>G</kbd> | Goto last slide |
| <kbd>O</kbd> | Open or lock the active Crowdplay poll |
| <kbd>V</kbd> | Reveal or hide Crowdplay results |
| <kbd>R</kbd> | Reset votes in the active Crowdplay poll |
| <kbd>E</kbd> | Enter or leave Studio visual editing mode |

**Beast Mode**: removes the 60 FPS limit

## Studio visual editing

Run rayslides without a slide file to begin with a blank, untitled slide in
Studio, pass `--studio` with a slide file to open that deck directly in Studio,
or press <kbd>E</kbd> while presenting an existing deck. Studio is a visual
authoring surface backed by the ordinary `.sld` source: every completed action
rewrites and reparses the document, so the GUI and text formats remain two
views of the same file.

Studio opens in a monitor-aware editing window (up to 1600×900) and fits the
16:9 slide into the space left by its chrome, so permanent controls never cover
slide content. Wide windows show the Slides/Library and Properties docks
together; narrower windows reserve one dock at a time through the toolbar
toggles. Press <kbd>Tab</kbd> for **Focus Canvas**, which hides all chrome while
leaving selection, guides, and direct manipulation active. Studio uses an
embedded, compact UI typeface independently of any fonts chosen by the deck.

The top toolbar contains these one-shot canvas tools:

| Tool | Shortcut | Action |
| ---- | -------- | ------ |
| Select | <kbd>V</kbd> | Select, move, and resize an existing object |
| Text | <kbd>T</kbd> | Click, then enter text for a new text box |
| Bullets | <kbd>B</kbd> | Click, then enter one bullet per line |
| Image | <kbd>I</kbd> | Click, then enter a path relative to the slide file |
| Rectangle | <kbd>R</kbd> | Click to add a colored shape |
| Library | <kbd>U</kbd> | Click, then name an existing reusable `@push` element |

Click an object and drag it to move it, or drag the cyan handle at its
bottom-right corner to resize it. The arrow keys nudge the selection by one
logical pixel; hold <kbd>Shift</kbd> to nudge by ten. Moves and resizes snap to
the slide and nearby object edges and centers, with magenta guides and a live
`x/y/w/h` readout. Hold <kbd>Cmd/Ctrl</kbd> during a drag to bypass snapping,
or press <kbd>G</kbd> to toggle the visible 20-pixel grid. Holding
<kbd>Shift</kbd> while resizing preserves the displayed aspect ratio, including
for auto-sized images. The property panel edits text, exact `x/y/w/h` values,
font size, opacity, foreground and item-background colors, duplicates or
deletes the object, promotes it for reuse, and aligns it to any slide edge or
center. Numeric width and height fields change only the chosen dimension, so
the other dimension of an auto-sized image remains automatic. Custom colors
accept `#RRGGBB` or `#RRGGBBAA`; opacity accepts `0.01`–`1` or `1%`–`100%`.
Zero opacity is intentionally refused until transparent objects can be
reselected through a layers view. Shift-click toggles objects into an ordered
multi-selection, and <kbd>Cmd/Ctrl-A</kbd> selects every editable object in the
current scene. Drag an empty part of the canvas to marquee-select everything
the rectangle overlaps; hold <kbd>Shift</kbd> to toggle the marquee hits against
the selection that existed when the drag began. A group can be dragged or
nudged as one unit; the same alignment buttons align its members to the
selection bounds, while **H Gap** and **V Gap** distribute three or more
objects with equal spacing. Group moves, layer changes, duplication, and
deletion are each written atomically as one undoable source edit. Resize, text,
color, and promotion remain single-object operations; Studio refuses them for
a group instead of silently changing only its primary item. Batch duplicate or
delete is likewise refused as a whole when any selected object's source
ownership cannot be handled safely.
The **Layer** controls move one or several selected objects backward, forward,
to the back, or to the front while preserving the group's internal paint
order. A layer change is also one atomic source edit.
<kbd>Cmd/Ctrl-N</kbd> or **+ Slide** inserts a new slide immediately after the
current one. <kbd>Esc</kbd> cancels an active drag or tool, then leaves Studio.

<kbd>Cmd/Ctrl-C</kbd> copies selected authored objects to Studio's internal
clipboard; <kbd>Cmd/Ctrl-V</kbd> pastes fresh objects into the current base or
morph scene. Every pasted object receives a unique `id=`, is offset by 20
logical pixels on each successive paste, and the entire paste is one undoable
edit. Auto-sized images retain automatic sizing. The safe clipboard scope is
deliberately source-aware: copy accepts literal direct `@box` items and direct
`@pop` component instances in the base scene. A copied `@pop` remembers the
exact `@push` definition it resolved to, and paste is refused if the destination
would bind it to a shadowing definition. Component instances are base-scene
only, while ordinary boxes may be pasted into a morph scene. Generated items,
inherited slide-template objects, backgrounds, and Crowdplay panels are refused
without changing the source. Clipboard snippets remain source-faithful rather
than materializing inherited defaults, so pasting onto a slide with different
font or color defaults may intentionally adopt that destination's appearance.

**Lock** writes `locked=true` on selected objects. Locked objects remain in the
rendered deck but are excluded from normal clicking, select-all, snapping,
geometry, properties, and layer mutations. Click the visible **LOCK** badge to
select one for read-only copying; click it again, use **Unlock**, or press
<kbd>Cmd/Ctrl-L</kbd> to write `locked=false`. Locks follow the same ownership
rules as other properties, including instance-local and morph-state `@set`
overrides; hold <kbd>Alt</kbd> for an intentional shared-template lock change.
A locked object is also a layer barrier, so a batch move that would cross it is
refused atomically.

The Studio sidebar is a deck organizer and source-aware library. Its slide
cards contain live rendered thumbnails and can select, add, duplicate, delete,
or move complete slides while preserving their base content, morph states,
comments, and line endings. The library lists the effective `@push` elements
and `@pushslide` templates available at the current source position. Click an
entry to select it, then choose **Use**: reusable elements become a one-shot
canvas placement tool at their authored size, while slide templates create the
next slide. **Ren** changes that definition and its source-order-resolved uses;
**Del** removes only unused element definitions. Slide-template deletion and
deleting elements with live uses are deliberately refused. Later or shadowed
definitions are absent because they would not resolve at that insertion point.

The organizer's **Tpl** action promotes an eligible direct slide into a named
`@pushslide` definition while leaving an equivalent `@popslide` instance in
its original deck position. Promotion is intentionally conservative: Studio
refuses template-backed slides or source whose global/default context cannot
be moved without changing semantics.

Text, bullet, image, and reusable-name actions open a small modal editor.
<kbd>Enter</kbd> commits, <kbd>Shift-Enter</kbd> inserts a line in text fields,
<kbd>Cmd/Ctrl-V</kbd> pastes, and <kbd>Esc</kbd> cancels without touching the
source.

Studio edits the `.sld` document rather than maintaining a separate opaque
scene. It changes only the source owned by the selected object and preserves
unrelated spacing, comments, text, and line endings. Objects instantiated with
`@pop` are edited at that instance. Named objects inherited from `@pushslide`
are also edited locally by default: Studio creates or updates an `@set` beside
the current `@popslide`, and Delete adds `@hide`. Hold <kbd>Alt</kbd> while
moving, resizing, nudging, or changing a property to edit the shared template
definition instead. This also works from an already-customized instance:
Studio retains the shared authored value layer and applies the gesture delta
there without baking the local coordinates into every slide. The current slide
keeps any properties it overrides. <kbd>Alt</kbd>-Delete removes the shared item
and its source-resolved local and morph mutations together; ambiguous or
generated dependency layouts are refused atomically. Template items use an
amber outline and the status bar states whether an operation is local or
shared. An inherited object without a unique `id=` cannot receive a local
override; add an ID or use <kbd>Alt</kbd> for an intentional shared edit. A
generated shared directive produced through `@let` remains read-only, but an
identified inherited item can still receive a later literal local override.
Background swatches write an item-owned `bg=` fill, so a local template
override stays behind its own text, image, or panel without creating a
z-order-sensitive sibling rectangle. Use the **None** background control to
write `bg=none` and clear an inherited or directly authored fill.

**Reuse** (or <kbd>P</kbd>) promotes a direct box to a named `@push` definition
and leaves an equivalent `@pop` instance in place. The Library tool creates
more instances later in the document. Reusable definitions are source-order
scoped, so a library item can only be placed after its definition.

| Studio shortcut | Description |
| --------------- | ----------- |
| <kbd>Cmd/Ctrl</kbd> + <kbd>S</kbd> | Atomically save changes to the original `.sld` file |
| <kbd>Shift</kbd> + <kbd>Cmd/Ctrl</kbd> + <kbd>S</kbd> | Save an `*.edited.sld` copy |
| <kbd>Cmd/Ctrl</kbd> + <kbd>Z</kbd> | Undo the last visual edit |
| <kbd>Shift</kbd> + <kbd>Cmd/Ctrl</kbd> + <kbd>Z</kbd> | Redo the last visual edit |
| <kbd>[</kbd> / <kbd>]</kbd> | Edit the base scene, previous morph state, or next morph state |
| <kbd>G</kbd> | Toggle grid display and grid snapping |
| <kbd>Tab</kbd> | Toggle Focus Canvas without leaving Studio |
| Hold <kbd>Shift</kbd> while resizing | Preserve the object's aspect ratio |
| Hold <kbd>Cmd/Ctrl</kbd> while dragging | Temporarily bypass smart guides and grid snapping |
| <kbd>Shift</kbd> + click | Add or remove an object from the current selection |
| Drag empty canvas | Marquee-select every overlapping object |
| <kbd>Shift</kbd> + drag empty canvas | Toggle marquee hits against the starting selection |
| <kbd>Cmd/Ctrl</kbd> + <kbd>A</kbd> | Select every editable object in the current scene |
| <kbd>Cmd/Ctrl</kbd> + <kbd>C</kbd> | Copy selected direct boxes or direct component instances |
| <kbd>Cmd/Ctrl</kbd> + <kbd>V</kbd> | Paste clipboard objects, offset by another 20 pixels |
| <kbd>Cmd/Ctrl</kbd> + <kbd>[</kbd> / <kbd>]</kbd> | Move the selection one layer down / up |
| <kbd>Shift</kbd> + <kbd>Cmd/Ctrl</kbd> + <kbd>[</kbd> / <kbd>]</kbd> | Move the selection to the back / front |
| <kbd>Cmd/Ctrl</kbd> + <kbd>L</kbd> | Lock or unlock the selected objects |
| <kbd>Backspace</kbd> | Atomically delete the selected object or selection |
| Hold <kbd>Alt</kbd> while editing a template item | Edit its shared definition instead of this instance |
| <kbd>Enter</kbd> | Edit the selected object's text |
| <kbd>P</kbd> | Promote the selected object for reuse |
| <kbd>Enter</kbd> | Use the selected library entry when no canvas object is selected |
| <kbd>F2</kbd> | Rename the selected library definition and its resolved uses |
| <kbd>Shift</kbd> + <kbd>Delete</kbd> | Delete the selected library definition when it is unused |
| <kbd>Cmd/Ctrl</kbd> + <kbd>N</kbd> | Insert a new slide after this slide |
| <kbd>Cmd/Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd> | Promote the current slide to a reusable slide template |
| <kbd>Page Up</kbd> / <kbd>Page Down</kbd> | Select the previous or next slide in Studio |
| <kbd>Cmd/Ctrl</kbd> + <kbd>D</kbd> | Atomically duplicate the selected object(s), or the current slide when none are selected |
| <kbd>Cmd/Ctrl</kbd> + <kbd>Backspace</kbd> | Delete the current slide (except the only slide) |
| <kbd>Alt</kbd> + <kbd>Shift</kbd> + <kbd>Up/Down</kbd> | Move the current slide when no object is selected; otherwise nudge the shared template item by ten |

The `*` beside `STUDIO` means the in-memory document differs from the original
file. Automatic file reload is paused while those unsaved changes exist.
Transitions are paused in Studio and ordinary reveal items are shown. The scene
control in the toolbar switches between the base scene and each semantic morph
state. Editing an inherited, named item creates or updates a state-local `@set`;
deleting it creates `@hide`. Items born in the active state are edited at their
own directive. Background creation and reusable promotion remain base-scene
operations because they change structural layout rather than one morph state.
Structural edits are also undoable. Layer changes support literal direct boxes,
direct component instances, and objects born in the active morph state, but do
not reorder inherited slide-template content. Items separated by a mutation,
definition, global default, or another source-ownership boundary cannot cross
it. Full-slide `@bg` items are pinned layer boundaries, so **Back** cannot hide
ordinary content underneath the slide background. If a layout cannot be moved,
copied, or duplicated unambiguously, Studio refuses the whole operation and
leaves the source intact.

Object duplication is also source-aware: it copies each complete item body and
owned reveal animation, assigns fresh stable `id=` values, offsets the clones
by 20 logical pixels, and leaves auto-image sizing untouched. A mixed batch of
direct boxes and direct `@pop` component instances is committed as one edit.
Inherited morph items, local slide-template clones, generated directives, and
crowd panels are conservatively refused when they cannot be duplicated without
changing their ownership semantics. Hold <kbd>Alt</kbd> with **Dup** or
<kbd>Cmd/Ctrl-D</kbd> to duplicate an uncustomized item in the shared slide
template.

If the original file changes externally, Studio refuses to overwrite it and
asks you to use Save Copy. Quitting with unsaved work also writes a unique
`*.edited.sld` recovery copy before closing; if that copy cannot be written,
the quit is cancelled.

# Slideshow Text Format

## Markdown Format

Bulleted items can be placed and nested like this:

```markdown
- first
    - second (4 space indendation)
        - third ...
```

Formatting is supported:

```markdown
Normal text.
**Bold** text.
_italic_ text.
_**Bold italic**_ text.
~~Underlined~~ text.
`rendered with "font_extra" (e.g. "zig showtime" font)`
<#rrggbbaa>Colored with alpha</> text. E.g. <#ff0000ff>red full opacity</>
```

Inline code uses an optical size correction derived from the active body and
`font_extra` glyph metrics. A blocky display face therefore stays distinctive
without overpowering adjacent prose. Its baseline is aligned from the same
metrics, and measurement, wrapping, shadows, rendering, and morphing all use
the corrected geometry. At a mixed-font boundary, whitespace uses the wider
space advance of its two neighbors, so neither body-to-code nor code-to-body
spacing becomes cramped.

### Symbols and emoji

Rayslides includes portable monochrome fallbacks for common presentation
symbols, even when a selected custom font does not contain them. They inherit
the surrounding text color, opacity, shadow, and animation.

The curated set includes directional arrows (`← ↑ → ↓ ↔ ↖ ↗ ↘ ↙`), media
controls (`▶ ◀ ⏩ ⏪ ⏸ ⏹ ⏺`), status marks (`✅ ✔ ❌ ⚠ ℹ ❓ ❗`), and useful
visual accents such as `✨ ⭐ ❤ 🎉 🎯 🏆 👍 👀 👏 💡 📈 📉 📌 🔥 🚀 🛠 🤖 🧠`.
Emoji variation selectors are accepted and ignored safely. Complex joined
emoji sequences are rendered as their supported individual glyphs rather than
as a single color ligature.

### Text shadows

Text boxes can draw a solid drop shadow without duplicating and offsetting the
same text manually. Set its color with `shadow=`; the default offset is four
pixels down and right:

```text
@push slide_title x=110 y=71 w=1712 h=100 fontsize=52 color=#eeeeeeff shadow=#000000a0

@pop slide_title text=A title with a drop shadow
```

Use `shadow_offset=` to set both coordinates, or `shadow_x=` and `shadow_y=`
for different offsets. Negative offsets are allowed. Shadow attributes inherit
through `@push`/`@pop`, and an inherited shadow can be disabled with
`shadow=none`:

```text
@box x=100 y=100 w=1700 h=200 fontsize=96 color=#f7a41dff shadow=#000000ff shadow_x=3 shadow_y=5 text=Shadowed text

@pop slide_title shadow=none text=No shadow on this instance
```

The shadow uses the same font, wrapping, markdown spans, reveal state, opacity,
and motion as its text. It is deliberately a crisp duplicate-text shadow, not
a blurred raster effect. As with other box attributes, place shadow attributes
before `text=` on an inline `@box` or `@pop` directive.

## Crowdplay: live audience participation

Crowdplay turns audience phones into live inputs without an app, account, or
cloud service. A deck containing `@crowd` starts a small LAN server, embeds a
self-contained phone client, and renders participants as an animated swarm.
Votes are unique per browser, retry-safe, and may be changed while a poll is
open.

Start with a join slide. rayslides displays a scannable QR code, the local URL,
and the live participant count:

```text
@bg color=#070b18ff
@crowd join x=100 y=80 w=1720 h=920
Scan to join the room
```

Add a poll with a stable `id=`. The first body line is the question and each
`- ` line is a choice:

```text
@bg color=#070b18ff
@crowd poll id=architecture open=true x=100 y=80 w=1720 h=920
What should we build next?
- A tiny compiler
- A moon base
- Both, obviously
```

Use <kbd>O</kbd> to open/lock voting, <kbd>V</kbd> to reveal the animated
distribution, and <kbd>R</kbd> to reset the poll. Revealing and locking are
independent, so you can show results while votes continue to arrive. Crowdplay items participate
in normal z-order, item animations, and slide transitions. A poll supports up
to eight choices; a deck supports up to 32 polls and 512 active participants.
Use one Crowdplay item per slide and unique poll IDs containing only letters,
digits, `-`, or `_`. IDs are limited to 48 bytes, prompts to 192 bytes, and
choice labels to 64 bytes. Omitted panel geometry defaults to
`x=100 y=80 w=1720 h=920`.

A Crowdplay `id=` is also a semantic-morph target. Declare the Crowdplay item
before the first `@state(morph)` and use `@set`, `@show`, or `@hide` to move,
resize, or fade the live panel while keeping its audience state intact.

The default audience address is `http://<computer-name>.local:7331/`. Override
the advertised hostname or port when mDNS is unavailable:

```sh
zig build run -- testslides/crowdplay.sld --crowd-host=192.168.1.42 --crowd-port=7331
```

Use `--no-crowd` to disable the server. Phones and the presenting computer must
be on the same network, and the local firewall must permit the selected port.
On Windows, pass `--crowd-host=<LAN-IP>`; `localhost` is only reachable from the
presenting computer itself.
The transport is deliberately ordinary HTTP with revision polling for maximum
phone/browser compatibility; the state and voting protocol remains suitable
for a future WebSocket transport.

## Slideshow Format

Internal render buffer resolution is 1920x1080. So always use coordinates in this range.

More documentation to follow.

## Slide-template instance overrides

Items in a reusable `@pushslide` template can be changed on one slide without
copying or detaching the template. Give the template item a stable `id=`, then
put `@set`, `@show`, or `@hide` after the corresponding `@popslide` and before
its first morph state:

```text
@box id=title x=100 y=70 w=1700 h=100 fontsize=52 text=Shared title
@box id=page_number x=1780 y=1010 w=80 h=40 text=$slide_number
@pushslide content

@popslide content
@set title x=180 color=#f7a41dff text=Local title for this slide
@hide page_number

@state(morph)
@set title y=500
```

The shared template remains unchanged. The base-scene override affects only
that `@popslide` instance, and subsequent morph states inherit it before
applying their own mutations. Targets must uniquely identify inherited
template items; ordinary direct slides still require an `@state(morph)` before
using these mutation directives. Studio writes this syntax automatically for
local geometry, text, colors, backgrounds, locking, and deletion. Holding
<kbd>Alt</kbd> explicitly edits the shared template item instead, including from
a customized instance: Studio keeps the shared authored value layer separate
from effective local values. Shared deletion removes source-resolved local and
morph mutations together; ambiguous or generated dependencies are refused
atomically.

For nested reusable elements, give `@pop` an explicit `id=` when local slide
overrides refer to it. That ID remains stable if the reusable definition is
renamed; relying on the component name as its implicit ID does not.

## Animations and slide states

Animations add reveal states to one logical slide; they do not duplicate the
slide. Unannotated content is visible immediately when the slide enters. A
one-shot `@anim(...)` annotation applies to the next `@box`, `@pop`, or `@bg`:

```text
@pop slide_title text=Why this matters

@anim(fade) by=bullet duration=0.25
@pop bigbox
Introductory text stays visible.
- First click reveals this bullet
- The next click reveals this one
    - Nested bullets are steps too
```

The forward controls (right arrow, Page Down, Space, or left click) reveal the
next step before moving to the next slide. Backward controls hide steps before
moving to the previous slide. The available effects are `appear`, `fade`,
`slide-left`, `slide-right`, `slide-up`, and `slide-down`. Animated elements
using a slide effect also fade; for example, `slide-left` enters from the right
and travels left. `appear` is instantaneous. The default effect is `fade`, the
default grouping is `item`, and the default duration is 0.3 seconds.

`by=` controls how a text box is split into states:

- `by=item` (the default) reveals the whole box or image together.
- `by=line` reveals each non-empty source line.
- `by=bullet` reveals only bullet lines; surrounding lines remain static.

Steps wait for a presentation action by default. Add `after=` to start them
automatically after the previous animation finishes:

```text
@anim(slide-left) by=bullet after=0.8 duration=0.25
@box x=100 y=200 w=1200 h=700
- Appears automatically
- Then this appears 0.8 seconds after the first animation finishes
```

The same annotation works on other items, including images:

```text
@anim(slide-up) duration=0.4
@box img=assets/diagram.png x=800 y=250 w=700
```

For compact cases, animation properties can be placed directly on the item:

```text
@box img=assets/diagram.png x=800 y=250 anim=fade after=1 duration=0.4
```

Slide transitions are properties of a slide boundary. Put them on a slide
template to reuse them or override them on one slide:

```text
@pushslide content transition=slide-left duration=0.35

@popslide content
# ...slide contents...

@popslide content transition=fade duration=0.5
# ...this slide fades in while the prior slide fades out...
```

Transitions use the same effect names. PDF export renders the final state of
each logical slide, so builds still produce one PDF page per source slide. A
transition lasts 0.4 seconds by default, automatically reverses direction when
navigating backwards, and can be disabled for one slide with
`transition=none`.

## Semantic morph states

Morph states let one logical slide change layout without copying the whole
slide. Give objects stable `id=` values, start a new state with
`@state(morph)`, and describe only what changes:

```text
@box id=hero img=assets/diagram.png x=1250 y=180 w=520 h=320
@box id=title x=120 y=180 w=1000 h=120 fontsize=72 shadow=#00000080 text=One object, many states

@state(morph) duration=0.8 ease=spring
@set hero x=0 y=0 w=1920 h=1080
@set title x=80 y=55 fontsize=48 color=#f7a41dff shadow_offset=7
```

Everything before the first state is the slide's initial state. Each
`@state(morph)` adds one forward/backward presentation step and begins a
cumulative patch over the previous state. Unspecified objects and properties
carry forward. The default duration is 0.6 seconds and the default easing is
`smooth`; the available easing modes are `linear`, `smooth`, and `spring`.
Bare `@state` is accepted as shorthand for `@state(morph)`.

Use the state directives to manipulate objects:

- `@set name ...` changes only the supplied properties.
- `@hide name ...` hides an object, optionally moving or restyling it while it
  fades out.
- `@show name ...` restores a hidden object, again allowing property changes.
- A normal `@box`, `@pop`, or `@bg` inside a state creates an object beginning
  in that state. It fades in automatically.

For example:

```text
@box id=caption x=120 y=900 w=1600 h=90 visible=false text=Initially hidden

@state(morph) duration=0.5
@show caption y=800

@state(morph) after=1.2 duration=0.5
@hide caption x=-1600
@box id=replacement x=120 y=800 w=1600 h=90 text=Born in this state
```

`after=` has the same meaning as it does for reveal animations: after the
previous step settles, wait that many seconds and start automatically. Going
backward pauses automatic progression and reverses the same interpolation.
Changing direction during a morph continues from the current frame.

Morphable properties include position and size (`x`, `y`, `w`, `h`),
`fontsize`, foreground `color`, item background `bg`, `bullet_color`,
`line_height`, `underline_width`, image `scale` and `ratio`, text-shadow
properties, and `opacity` from `0` to `1`. Use `bg=#rrggbbaa` for a bounded
fill behind that item and `bg=none` to clear it; this is distinct from the
slide-wide `@bg` directive. Text content and an existing image object's `img=`
path may also change.
Rayslides interpolates geometry, font size, colors, opacity, and shadows when
the rendered content is compatible. Changed text, changed images, wrapping
changes, new objects, and removed objects use a cross-fade instead, avoiding
scrambled text fragments.

IDs are local to one logical slide and must be unique on any slide that uses
morph states. A named `@pop` automatically uses its template name as its ID,
unless an explicit `id=` overrides it:

```text
@push slide_title x=100 y=70 w=1700 h=100 fontsize=52
@slide
@pop slide_title text=This can be targeted as slide_title
@state(morph)
@set slide_title x=500 color=#f7a41dff
```

Ordinary `@anim` reveals belong before the first morph state; they run first.
Objects born inside a morph state already animate as part of that state, so
`@anim`/`anim=` is intentionally rejected there. PDF export renders the final
state while still producing one page per logical slide. Reusable
`@pushslide` templates must remain static; add morph states to the logical slide
after `@popslide`. See the semantic morphing slide in
[`test_public.sld`](./testslides/test_public.sld) for image takeover, title
restyling, moving exits, automatic states, and bullets rearranging into a
flowchart.

Example of the current text format - see [test_public.sld](./testslides/test_public.sld) for a more realistic example:

```
# lines starting with a # sign are comments

# -------------------------------------------------------------
# -- intro slide template
# -------------------------------------------------------------

# Background image

# for a simple colored background:
@bg color=#181818FF

# or a background image:
# @bg img=assets/bgwater.jpg

# change default line height from 1.0 to 1.2
@line_height=1.2

# often-used text elements
@push intro_title    x=150 y=400 w=1700 h=223 fontsize=96 color=#7A7A7AFF
@push intro_subtitle x=219 y=728 w=836 h=246 fontsize=45 color=#cd0f2dff
@push intro_authors  x=219 y=818 w=836 h=246 fontsize=45 color=#993366ff

# the following pushslide will the slide cause to be pushed ("remembered as template"), not rendered
@pushslide intro

# auto-incrementing slide-number is in $slide_number
@push slide_number x=1803 y=1027 w=40   h=40  fontsize=20 color=#404040ff text=$slide_number

# -------------------------------------------------------------
# -- content slide template
# -------------------------------------------------------------
@bg color=#181818FF
@pop slide_number
@pushslide content


# #############################################################
# ##   S  L  I  D  E  S
# #############################################################

# -------------------------------------------------------------
@popslide intro
@pop intro_title text=!Slideshows in <#F7A41DFF>ZIG</>!
@pop intro_subtitle text=_**Easy, text-based slideshows for Hackers**_
@pop intro_authors text=_@renerocksai_

# -------------------------------------------------------------
# Some slide without slide template
# -------------------------------------------------------------
@popslide content

# Images can be placed with explicit dimensions:
# @box img=some_image.png x=800 y=100 w=320 h=200

# Or use auto-dimensions (uses the image's natural size):
# @box img=some_image.png x=800 y=100

# Scale the auto-dimensions:
# @box img=some_image.png x=800 y=100 scale=0.5

# Adjust aspect ratio (w/h) after scaling:
# @box img=some_image.png x=800 y=100 scale=0.5 ratio=0.5

# Only specify width (height auto-calculated to preserve aspect ratio):
# @box img=some_image.png x=800 y=100 w=320

@box x=100 y=100 w=1720 h=880 color=#FFFFFFFF
Here come the bullets:
`
Text in a box can span multiple lines and will be wrapped
according to width
`
`
`
Empty lines consist of a single backtick (see above and below)
`
`
`
Bullet list:
- first
    - some details
- second
- <#808080ff>third</> in a different color
```

# Building it

Requires Zig 0.16.x (minimum 0.16.0). Just `zig build`; see
[`build.zig.zon`](./build.zig.zon) for the minimum required Zig version.

```console
$ zig build run -- testslides/test_public.sld
```
