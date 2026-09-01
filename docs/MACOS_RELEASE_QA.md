# macOS release QA

This checklist covers application boundaries that headless source-editor tests
cannot fully exercise: native input focus, Spaces/monitors, window transitions,
GPU resources, and isolation between Studio chrome and presentation/export.
Run it from a clean worktree with a ReleaseSafe build.

Build the non-notarized Rayslides application bundle separately with:

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

Workspace 12 and floating layout are **automation isolation**, not Rayslides
release criteria. The harness owns that placement so its windows do not disturb
the active workspace; a placement failure means the harness must be repaired or
rerun, not that the product failed visual QA. Aerospace is already configured
to open Rayslides windows floating, and the harness still verifies the final
queried state after moving each exact window.

Record the commit, macOS version, monitor arrangement/scaling, and whether each
section below passed. Attach `zig-out/studio-baselines/*.log` and any
`*.diff.png` when reporting a failure.

Recorded 2026-08-22: all four automated scenarios passed after the harness
verified each exact Rayslides window as floating on workspace 12. A separate
copied-bundle run outside the checkout received a LaunchServices document event
for a copied portable show, loaded its relative PNG and MP4, and visually
refreshed Showtime to `READY FOR SHOW` with 9 render fragments, 2 assets, and 1
definition. The ordinary and in-bundle executables both returned version/help
without opening a window; the bundle advertises `.sld` and its Studio artwork
icon. A later copied-bundle venue run confirmed the physically connected LG HDR
4K display (3840×2160 at 60 Hz), visually passed the picker and Showtime, and
served healthy Presenter and Crowdplay LAN endpoints. Every exact Rayslides
window was verified floating on workspace 12 before its capture gate opened.
A final copied-bundle Presenter run used 430×932 and 932×430 browser frames to
verify phone portrait/landscape layout, navigation, pointer, drawing, Clear,
same-tab capability recovery, and fail-safe host suspend/resume. A projected
drawing was visually captured. A final clean Chrome geometry run at 430×932,
932×430, and 1280×800 asserted the intended phone/laptop breakpoint, no
horizontal overflow, and the complete landscape surface plus Clear action
above fixed navigation. These checks do not replace physical-phone, hotspot,
sleep/wake, hardware-touch, or real-projector rehearsal.
A subsequent iPhone 17 Pro iOS 26.5 Simulator run paired the rebuilt copied app
in Mobile Safari. Simulated Previous/Next, Draw, Clear, and a finger drag used
the production client queues; the stroke was captured on the Rayslides window.
The complete compact landscape surface and Clear action remained above fixed
navigation, Notes retained its full layout, and Mobile Safari reconnected to
the continuing talk after a full Simulator shutdown and boot. This remains
Simulator/WebKit evidence and does not close any physical-phone, hotspot,
sleep/wake, Android, latency, or real-projector checklist item.

## 1. Launch, focus, and monitor placement

- [x] Copy `zig-out/Rayslides.app` and a deck with relative images/video to a
      temporary directory outside the checkout. Deliver the same LaunchServices
      document event used by Finder/Open With and require the external deck plus
      every relative asset to load.
- [x] The app launch does not request broad Documents-folder access. Its
      neutral working directory is `$HOME`; app recovery uses
      `~/Library/Application Support/Rayslides/Recovery`.
- [x] Verify the bundle icon is the Studio light-sculpture artwork, the `.sld`
      type is advertised, and `--version`/`--help` work from both the ordinary
      CLI and the executable inside the bundle without opening a window.
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

## 6. Embedded Neovim (enabled build)

- [ ] Build `zig build -Dneovim=true -Doptimize=ReleaseSafe macos-app`, copy
      the app outside the checkout, and verify its Resources contain the
      `nvim` runtime plus `fonts/JetBrainsMono-Regular.ttf` and the OFL text.
      `licenses/MPack-LICENSE.txt` must also be present. The bundle must not
      contain or require a bundled Neovim executable.
- [ ] From a Finder launch, open whole-source and eligible expanded text,
      bullet, and speaker-note editors with Neovim installed through Homebrew
      on Apple Silicon/Intel, MacPorts, and one user-local/shim location as
      available. Repeat once with no discoverable executable and require the
      built-in field editor fallback.
- [ ] Run `--neovim-clean`, then normal configuration. Verify Command and
      Option mappings, composed Unicode, clipboard paste, mouse selection and
      wheel input, focus switching, Retina scaling, and resizing at compact,
      default, and large window sizes.
- [ ] Launch once each with `--neovim-path`, `--neovim-font`, and
      `--neovim-font-size`. Verify the configured primary face remains
      monospaced and the complete supported monochrome emoji set renders with
      the bundled fallback.
- [ ] Exercise every write/quit row in `NEOVIM_EDITOR_ROADMAP.md`. Confirm
      rejected writes retain the overlay, ordinary Rayslides shortcuts remain
      suspended while it is open, close restores Studio input once, and app
      quit reaps only the exact child without a recovery copy for unapplied
      Neovim changes.
- [ ] Run `zig build -Dneovim=true -Doptimize=ReleaseSafe neovim-baselines --
      --workspace 12` from the copied-bundle QA environment and review all
      three overlay captures.

## 7. Shutdown hygiene

- [x] Quit every Rayslides process after the checks.
- [x] `aerospace list-windows --all ... | rg -i rayslides` returns nothing.
- [x] `git status --short` contains no recovery copies, exported images/PDFs,
      temporary decks, Python caches, or other QA residue.
