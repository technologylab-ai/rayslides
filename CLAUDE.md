# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rayslides is a minimalistic slideshow presentation tool written in Zig, using raylib for rendering. It's a port of the original [slides](https://github.com/renerocksai/slides) project, designed for editing, presenting, and PDF-exporting slides on Mac (and other platforms via raylib).

## Build Commands

```bash
# Build the project
zig build

# Run with a slideshow file
zig build run -- testslides/test_public.sld

# Run tests
zig build test
```

**Requirements:** Zig 0.16.x (minimum 0.16.0, specified in build.zig.zon). Video playback additionally needs `ffmpeg`/`ffprobe` installed at runtime.

## Architecture

### Core Components

- **main.zig** - Application entry point, main loop, input handling (keyboard/mouse), and window management. Contains `AppData` global state struct (`G`), `ExportController` for PDF export, `LaserPointer` for presentation annotations, and `Banner` for splash screen.

- **parser.zig** - Parses `.sld` slideshow text files into slide data structures. Handles directives (`@bg`, `@box`, `@push`, `@pop`, `@slide`, `@pushslide`, `@popslide`), variable substitution (`@let`), and font configuration. The `ParserContext` manages parsing state and template contexts.

- **renderer.zig** - `SlideshowRenderer` pre-renders slides into `RenderElement` lists (background/text/image), then renders them at runtime with coordinate transformation from internal 1920x1080 space to window size.

- **slides.zig** - Data structures: `SlideShow` (collection of slides with defaults), `Slide` (items + per-slide settings), `SlideItem` (background/textbox/img with position, size, color, font), `ItemContext` (parsing context for directives).

- **markdownlineparser.zig** - Parses markdown-like inline formatting within text: `**bold**`, `_italic_`, `~~underline~~`, `` `code` ``, `<#rrggbbaa>colored</>`.

- **fonts.zig** - Font loading and management, supports custom fonts via `@font`, `@font_bold`, etc. directives.

- **texturecache.zig** - Caches loaded image textures to avoid redundant loading.

- **videoplayer.zig** - Video playback by piping raw frames/PCM from external `ffmpeg` processes (no codec libraries linked). `VideoPlayer` streams into a texture and a raylib AudioStream; `VideoCache` mirrors texturecache, one shared player per video file.

### Rendering Pipeline

1. **Parse**: `parser.constructSlidesFromBuf()` parses .sld file into `SlideShow` struct
2. **Pre-render**: `SlideshowRenderer.preRender()` converts slides into `RenderElement` lists
3. **Render**: `SlideshowRenderer.render()` draws elements with coordinate scaling

### Coordinate System

Internal render buffer is fixed at 1920x1080. All .sld coordinates use this space. The renderer scales to actual window size while maintaining aspect ratio.

### Slideshow Format

The `.sld` format uses directives prefixed with `@`:
- `@bg color=#rrggbbaa` or `@bg img=path` - slide background
- `@box x=N y=N w=N h=N fontsize=N color=#rrggbbaa` - text box (text follows on subsequent lines)
- `@box img=path x=N y=N` - image with auto-dimensions (uses image's natural size)
- `@box img=path x=N y=N scale=0.5` - image scaled to 50% of natural size
- `@box img=path x=N y=N scale=0.5 ratio=0.5` - scaled with adjusted w/h ratio
- `@box img=path x=N y=N w=N` - image with specified width, height auto-calculated
- `@box vid=path x=N y=N w=N` - video (decoded by piping frames from the installed `ffmpeg`; audio plays too). Same auto-dimension rules as images, plus `autoplay` and `loop` flags. Keys: `m` play/pause, `Shift+M` stop
- `@push name` / `@pop name` - save/restore element templates
- `@pushslide name` / `@popslide name` - save/restore slide templates
- `@let var=value` - variable substitution (`$var$` in text)
- `@line_height=N`, `@fontsize=N`, `@font=path` - global settings

Text supports markdown-like formatting and bullet lists (lines starting with `-` or `>`).

## Dependencies

- **raylib-zig** - Zig bindings for raylib (graphics/window)
- **pdfgen.c** - Embedded C library for PDF export (in src/pdf/)
