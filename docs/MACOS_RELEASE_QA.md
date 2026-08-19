# macOS release QA

This checklist covers application boundaries that headless source-editor tests
cannot fully exercise: native input focus, Spaces/monitors, window transitions,
GPU resources, and isolation between Studio chrome and presentation/export.
Run it from a clean worktree with a ReleaseSafe build.

Build the non-notarized Finder application separately with:

```sh
zig build -Doptimize=ReleaseSafe macos-app
```

## Automated gate

```sh
zig build release-confidence
zig build -Doptimize=ReleaseSafe macos-release-qa -- --workspace 12
```

The first command runs all Zig tests plus the baseline comparator self-test.
The second launches four short-lived Studio scenarios. For every launch it
identifies the exact process window, moves it to Aerospace workspace 12, makes
it floating, verifies window ID/workspace/layout, captures, compares, and
quits. A failed placement aborts before the application capture gate opens.
Use another workspace number when deliberately testing a different Space.

Record the commit, macOS version, monitor arrangement/scaling, and whether each
section below passed. Attach `zig-out/studio-baselines/*.log` and any
`*.diff.png` when reporting a failure.

## 1. Launch, focus, and monitor placement

- [ ] Copy `zig-out/Rayslides.app` and a deck with relative fonts/images to a
      temporary directory outside the checkout. Cold-open the deck through
      Finder/Open With and require the external deck plus every relative asset
      to load.
- [ ] The app launch does not request broad Documents-folder access. Its
      neutral working directory is `$HOME`; app recovery uses
      `~/Library/Application Support/Rayslides/Recovery`.
- [ ] Verify the bundle icon is the Studio light-sculpture artwork, the `.sld`
      type is advertised, and `--version`/`--help` work from both the ordinary
      CLI and the executable inside the bundle without opening a window.
- [ ] Launch `zig-out/bin/rayslides testslides/studio-showcase.sld --studio --no-startup-banner`.
- [ ] Query the launched PID with
      `aerospace list-windows --monitor all --pid PID --format '%{window-id}|%{workspace}|%{app-name}|%{window-layout}'`.
- [ ] Move that window with `aerospace move-node-to-workspace --window-id ID 12`
      and `aerospace layout --window-id ID floating`; query again and require
      `12|rayslides|floating` before evaluating the intended monitor.
- [ ] Typing in a Properties field goes only to that field. Tab/Shift-Tab stay
      inside the Inspector; Escape cancels the draft; Cmd-K searches Commands.
- [ ] Switching away and back does not synthesize a click, key, drag, or close.
- [ ] Move the floating window to the other monitor/Space and back. Text,
      pointer hit targets, rulers, and thumbnails remain aligned at both scale
      factors.

## 2. Resize, docks, and fullscreen

- [ ] Resize to 900×506, 1600×900, and the large monitor area. No toolbar,
      slide picker, Library, Objects, Properties, status, or morph strip
      overlaps the slide canvas or another panel.
- [ ] Toggle Slides, Objects, Properties, Focus Canvas, and Tab at compact and
      default sizes. Hidden docks neither draw nor capture input.
- [ ] Begin a move/resize gesture, resize the native window, and verify the
      gesture cancels without changing source.
- [ ] Enter and leave fullscreen twice. The prior floating window dimensions
      and position return; 60 Hz/vsync behavior remains stable without flash.

## 3. Transactional reload and source edits

- [ ] Work on a temporary copy of the showcase deck. Make one Studio edit and
      verify an external file change does not replace the dirty buffer.
- [ ] With the buffer clean, leave Studio so presentation-mode file polling is
      active, then write parser-invalid source externally. The rejected reload
      leaves the current rendered deck on screen. Re-enter Studio and verify
      **Reload failed – the current document is still open**;
      the current slide, rendered graph, Studio selection, Undo/Redo, and
      internal clipboard remain usable.
- [ ] Restore parser-clean source. The next poll commits it once, clears
      document-scoped history/clipboard, and keeps Studio enabled.
- [ ] Trigger an unsupported/generated-source edit. It changes neither source,
      dirty state, history, selection, nor rendered output.

## 4. Save As, conflict, and recovery

- [ ] Launch without a file, choose a starter, edit it, and Save As a unique
      `.sld`. The file is byte-equal to the editor source and the dirty marker
      clears.
- [ ] Attempt Save As to an existing file. It is refused without overwriting
      the destination and the untitled session remains retryable.
- [ ] Externally change a named deck, then save the stale Studio buffer. The
      conflict notice recommends Save Copy and preserves both versions.
- [ ] Close a dirty deck without saving. Exactly one unique `.edited.sld`
      recovery copy is created beside a writable named source; its bytes
      reparse cleanly. Verify an untitled app session and an unwritable named
      source fall back to `~/Library/Application Support/Rayslides/Recovery`.
      Direct CLI untitled recovery remains in its current directory. If no
      recovery can be written, quitting is cancelled and the source stays open.

## 5. Presentation and export isolation

- [ ] Leave Studio or use Focus Canvas. Presentation occupies the complete
      window and has no Studio crop, dock offset, guide, selection, or tooltip.
- [ ] Navigate steps, morph states, and slide transitions before and after
      returning to Studio; authored scene selection and playback do not leak.
- [ ] Create a screenshot and PDF. Output is 16:9 slide content only—no chrome,
      margins, diagnostics HUD, cursor, laser drawing, or geometry preview.
- [ ] Cancel or finish export, return to the original slide/step, then edit and
      Undo/Redo once to verify GPU/parser ownership is still sound.

## 6. Shutdown hygiene

- [ ] Quit every Rayslides process after the checks.
- [ ] `aerospace list-windows --all ... | rg -i rayslides` returns nothing.
- [ ] `git status --short` contains no recovery copies, exported images/PDFs,
      temporary decks, Python caches, or other QA residue.
