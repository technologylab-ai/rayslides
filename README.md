# rayslides -- [slides](https://github.com/renerocksai/slides) ported to raylib

See [here](https://github.com/renerocksai/slides) for the original slides project.

This port is minimalistic, and I wrote it to be able to edit, present, and PDF-export slides on a Mac.

Due to the new [raylib](https://github.com/raysan5/raylib) dep, builds should work on all 3 major platforms now.

![screenshot](rayslides.jpg)

Missing but maybe coming soon:

- SDF-based font scaling

Missing but probably not coming soon:

- PPTX Export
- Editor
- Inspector Gadget

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

**Beast Mode**: removes the 60 FPS limit

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

## Slideshow Format

Internal render buffer resolution is 1920x1080. So always use coordinates in this range.

More documentation to follow.

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
