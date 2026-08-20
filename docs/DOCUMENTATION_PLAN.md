# Documentation plan

This file tracks the documentation work that remains after the first site draft.

## Source audit

- [x] Map the Studio controls to their source behavior.
- [x] Map the Presenter and Crowdplay interfaces to their shipped HTML.

## Studio workflows

- [x] Explain multi-selection.
  - Show Shift-click.
  - Show a marquee selection.
  - Show Select All.
  - Explain group movement and selection bounds.
- [x] Explain the Slides panel.
  - Show Add, Duplicate, Delete, Up, Down, and Template.
  - Explain Find, Previous, and Next.
- [x] Explain Library management.
  - Show Use, Edit, Rename, Delete, and Clean.
  - Explain item, group, and slide definitions.
  - Explain use counts and deletion limits.
- [x] Explain the Properties actions.
  - Show Duplicate, Delete, Reuse, and Lock.
  - Explain the color palettes and `none`.
- [x] Explain the creation tools.
  - Show Text, Bullets, Image, Rectangle, and Library placement.
- [x] Explain Focus and compact modes.
  - Show Focus, Slides, and Inspector.
  - Show the narrow-window layout.
- [x] Explain the status bar.
  - Show the selection count, source line, edit scope, geometry, notices, and errors.
- [x] Explain clipboard workflows.
  - Show Copy, Paste, and Duplicate.
  - Explain unsupported selections.

## Motion and shared content

- [x] Refine the morph timeline guide.
  - Show the timeline controls at a readable size.
  - Explain state delay, duration, easing, and order.
  - Show a selected state and a selected object.
- [x] Explain local and shared edits.
  - Compare an instance override with a definition edit.
  - Show the affected use count before a shared edit.

## Phone interfaces

- [x] Replace the Presenter phone mock-up with real interface evidence.
  - Show Notes, Pointer, and Draw.
- [x] Add Crowdplay audience evidence.
  - Show the voting screen.
  - Show the result view.

## Final review gate

- [x] Run automated checks after all content changes.
  - Validate the HTML.
  - Check local links and image references.
  - Match each declared image size to the source file.
  - Reject blank images and unintended duplicates.
- [x] Render every page at desktop and mobile sizes.
- [x] Inspect every rendered section after the final file change.
- [x] Confirm that every figure proves its caption.
- [x] Confirm that interface text stays readable at the displayed size.
- [x] Confirm that comparison images show distinct states.
- [x] Confirm that all images keep their aspect ratio.
- [x] Confirm that the docs use the app icon and no substitute logo.

## Capture safety

- [x] Warn the user before a Rayslides launch.
- [x] Close each capture process before reviewing its output.
- [x] Write review artifacts only to a temporary directory.
- [x] Never write a review contact sheet into `docs/images`.
- [x] Re-run the complete review after any image changes.
