# Rayslides Neovim editor roadmap

Status: Linux initial feature complete, including whole-document and expanded
field editors; macOS packaging seams are implemented and native macOS QA
remains, 2026-09-01.

This roadmap records the product contract, architecture, delivery order, and
completion gates for rendering an embedded Neovim editor inside Rayslides. It
is deliberately separate from the general Studio roadmap: the editor is an
optional integration that must never weaken the built-in authoring path or the
source-native transaction boundary.

## Outcome

Rayslides will offer a modal, raylib-rendered Neovim overlay for editing either
the complete in-memory `.sld` document or the values currently handled by
Studio's expanded `...` editors. Rayslides is the external UI frontend;
Neovim runs as an out-of-process `nvim --embed` child and communicates over
MessagePack-RPC through inherited pipes.

The integration is not a terminal emulator. Rayslides sends Neovim API input
and mouse calls, consumes line-grid redraw events, and paints the resulting
cell grid in its existing window.

## Product decisions

- `.sld` remains the only source of truth. Neovim edits a controlled buffer
  seeded from Studio memory, never a second project representation.
- A Neovim write means **apply through Rayslides**, not bypass Studio and write
  the deck file directly. The normal Rayslides Save/Save As boundary remains
  responsible for filesystem conflict checks and disk persistence.
- Whole-document Apply parses a complete candidate before changing live state.
  A successful apply is one ordinary Studio history entry; a failed parse
  changes neither source, render graph, selection, nor history.
- Expanded property, item-text, bullet, and speaker-note editors reuse the
  same Neovim host and overlay, but submit through their existing semantic
  source-edit operations rather than replacing an arbitrary serialized range.
- Neovim undo is local to the open buffer. Studio undo/redo records each
  successful Neovim write as an accepted source transaction.
- The user's ordinary Neovim configuration is the default experience. A clean
  mode and the built-in Rayslides editor remain recovery paths for broken or
  undesired configurations.
- Neovim support is a compile-time feature. A disabled build contains the stub
  integration only and does not compile or fetch the RPC/MessagePack/grid
  implementation.
- Linux is the first runtime/QA target. macOS uses the same architecture and
  follows after the Linux vertical slice. Windows retains the stub for this
  roadmap.
- Initial rendering uses one composed line grid. External multigrid, cmdline,
  messages, popup-menu, and tabline surfaces are deferred until evidence shows
  that the composed grid is insufficient.
- Initial source updates are explicit writes/applies. Debounced live preview
  from `nvim_buf_attach` events is a later enhancement, not an MVP dependency.

## Write, quit, and process-lifecycle contract

The Neovim buffer is an editor session with ordinary Vim exit semantics. The
overlay lifetime follows that session rather than requiring a separate
Rayslides-only close gesture.

| Neovim action | Rayslides result |
| --- | --- |
| `:w` | Validate and apply through Rayslides; retain the overlay and mark the Neovim buffer clean on success. |
| `:wq`, `:x`, or `ZZ` | Validate and apply when a write is required, then close the overlay. If validation fails, abort the quit and keep the overlay open at the diagnostic. |
| `:q` on an unmodified buffer | Close the overlay without another source transaction. |
| `:q` on a modified buffer | Preserve Neovim's normal unsaved-changes refusal; keep the overlay open. |
| `:q!` or `ZQ` | Discard changes since the last successful apply and close the overlay. |
| `:qa` | Follow the same clean/modified rule as `:q` for the controlled buffer. |
| `:qa!` | Discard changes since the last successful apply and close the overlay. |
| Rayslides **Apply and close** | Invoke the same guarded behavior as `:wq`; it is not a parallel commit path. |
| Rayslides **Discard** | Invoke the same behavior as `:q!`. |
| Child EOF, crash, or forced child termination | Close the overlay immediately. Keep only edits from writes that Rayslides already acknowledged; discard every unapplied buffer change. |

If Neovim is reused between overlays, closing an editor window may leave a
private parking window/process alive. That is an implementation detail:
`BufWinLeave`/buffer lifecycle notifications still close the visible Rayslides
overlay. If the child process exits entirely, the next editor request may
start a fresh process.

Write handling must be synchronous from Neovim's perspective. A controlled
`acwrite` buffer uses `BufWriteCmd` to request a host apply and only clears
`modified` after Rayslides acknowledges success. This is what makes `:wq`
abort safely when the slideshow parser or semantic property validator rejects
the candidate.

## Runtime architecture

```text
raylib keyboard / text / mouse
              |
              v
       outbound RPC queue -----> nvim --embed stdin
                                      |
                                      v
main-thread overlay <---- grid snapshots <---- blocking RPC reader
       |                                      nvim stdout/stderr
       |
       +---- Apply request ---- isolated parser / semantic source edit
                                      |
                                  Studio history
                                      |
                                  live render graph
```

### Build boundary

- Add `-Dneovim=true|false` with `b.option(bool, "neovim", ...)` and expose the
  selected value through the existing `build_options` module.
- Select real and stub modules with the same public host API. Application code
  must not scatter target or feature conditionals across the main loop.
- Default the option on for Linux/macOS after the feature is stable and off for
  other targets. During development it may remain default-off.
- If an external MessagePack source package is used, mark it lazy and request
  it only in the enabled branch so a disabled build neither fetches nor
  compiles it.
- An explicit enabled build for an unsupported target fails during build
  configuration with a concise explanation; the platform default remains a
  working stub build.

### Neovim host and transport

- Spawn `nvim --embed` directly with an argv array, never through a shell and
  never with `--headless` for a UI session.
- Resolve a configured executable first, then platform-appropriate PATH and
  common installation locations. Report the searched locations without
  treating a missing executable as an application failure.
- Use a blocking reader thread for stdout and a synchronized writer/outbound
  queue. Correlate request IDs, accept interleaved responses/notifications,
  enforce message/depth/string/collection limits, and reject malformed input
  without corrupting host state.
- Drain stderr independently so verbose plugins cannot deadlock the child;
  retain a bounded tail for actionable failure reporting.
- Discover API metadata and channel identity, advertise Rayslides with
  `nvim_set_client_info`, register the write/close callbacks, attach the UI,
  and wait for a deterministic ready notification before opening a document
  buffer.
- Reap the exact child process on normal exit. On application shutdown,
  request a graceful exit, wait for a short bounded interval, then terminate
  and reap only that child.

### Minimal UI protocol

Attach with RGB and `ext_linegrid`; leave multigrid and the other external UI
extensions disabled. The first renderer handles:

- grid resize, clear, line updates, scroll, and destruction;
- default colors and highlight definitions;
- cursor position, mode information/changes, mouse enablement, busy state,
  focus, and redraw `flush` boundaries;
- double-width continuation cells, multi-codepoint cell text, repeated cells,
  reverse colors, bold, italic, underline/undercurl/strikethrough, and a safe
  fallback for unsupported decorations;
- unknown events, extra parameters, unknown highlight keys, and MessagePack
  extension values without failing the stream.

The reader publishes bounded CPU-side grid snapshots or redraw batches. Only
the main thread touches raylib textures, fonts, and drawing calls.

### Input and overlay behavior

- Route printable/composed text without double-delivering raylib key events.
  Map special keys and modifiers to Neovim key notation and escape literal
  angle brackets correctly; use `nvim_paste` for clipboard and larger composed
  text.
- Translate clicks, releases, drag, movement, and vertical/horizontal wheel
  input into `nvim_input_mouse` cell coordinates.
- Resize the UI grid whenever the overlay rectangle or window scale changes,
  and notify Neovim of focus transitions when the negotiated API supports it.
- While active, the overlay owns keyboard/mouse input and suppresses Studio
  shortcuts except an explicit fail-safe host escape that cannot be confused
  with normal Neovim Escape.
- Render a dedicated monospaced font and calculate the grid strictly from its
  cell metrics. The initial bundled font must cover ordinary source text and
  common editor symbols; missing glyphs degrade visibly rather than corrupting
  cell positions.

### Controlled buffers and source transactions

- Whole-source mode copies `G.editor_memory[0..G.source_len]`, not the disk
  file. It records the opening source revision and refuses a stale apply if
  application state somehow changes behind the modal overlay.
- Preserve a UTF-8 BOM, dominant LF/CRLF convention, and final-newline state.
  Reuse original separators for unchanged lines when mixed line endings are
  present so opening and writing an otherwise untouched buffer is byte-stable.
- Enforce the current source-capacity limit before parsing or replacing live
  memory.
- Parse whole-source candidates in an isolated graph. On error, keep the last
  valid live slideshow, place diagnostics in the Neovim buffer, move to the
  first error when appropriate, and return a write error so `:wq` cannot exit.
- Route field buffers through their existing semantic command and ownership
  checks. Shared-template, local-instance, direct, and morph-state edits retain
  their current exact-source guarantees.
- A no-op write creates no Studio history entry. After a successful write,
  update the buffer's accepted baseline so a later forced quit discards only
  subsequent edits.
- Name buffers with a non-filesystem Rayslides URI and disable swap/backup
  behavior that could imply Neovim owns the deck file.

### Bundled `.sld` runtime

- Ship `ftdetect`, `syntax`, and only the minimal buffer-local settings needed
  for `filetype=rayslides` under a private runtime directory.
- Prepend that directory to the child runtime path without replacing the
  user's configuration or colorscheme.
- Highlight the real parser grammar and markdown-like content with conventional
  highlight groups, not hard-coded colors. Keep regexes bounded and include a
  representative automated syntax fixture.
- Start with classic Vim syntax. A Tree-sitter grammar, completion engine, or
  language server requires an independently justified roadmap.

## Delivery tranches

### 0. Completed: build seam and protocol proof

- [x] Add the OS-aware `-Dneovim` option, build option, and real/stub module
  selection without changing behavior when disabled.
- [x] Add the MessagePack implementation behind the enabled branch with its
  pinned source/license notice and no disabled-build fetch/compile cost.
- [x] Unit-test incremental framing across arbitrary read fragmentation,
  concatenated messages, all scalar/container/extension forms, unknown-value
  skipping, malformed data, and configured bounds.
- [x] Reproduce the researched attach/input/grid/clean-exit proof from Zig as
  an opt-in integration test that skips cleanly when `nvim` is unavailable.

Exit gate: both feature states build and test; the enabled integration test can
attach a small UI, observe a redraw flush, insert text, read it back, and reap
the child without touching Studio.

### 1. Host lifecycle and one-grid renderer

- [x] Implement child startup/readiness, request correlation, bounded stderr,
  exact-child teardown, EOF/crash detection, and a fresh session on
  the next open.
- [x] Implement the CPU grid/highlight/cursor model with unit coverage for
  colors, modes, repeated cells, scrolling, oversized grapheme fallback, and
  redraw flushes.
- [x] Expand fixture coverage for fragmented redraw batches, wide and combining
  cells, missing highlights, and unknown redraw events.
- [x] Render a resizable, clipped raylib overlay with user colorscheme, mode
  cursor, status feedback, and no GPU work off the main thread.
- [x] Bundle a redistribution-safe monospace font instead of relying on the
  current platform font search and raylib fallback.
- [x] Add a deterministic diagnostic launch mode for the editor overlay.
- [x] Add compact/default/large visual baselines for the exact overlay geometry.

Exit gate: a real Neovim welcome/scratch grid remains visually and
interactively correct during typing, scrolling, mode changes, mouse use, and
window resize on Linux.

### 2. Input, write, and quit contract

- [x] Forward Unicode text, special keys, modifiers, paste, pointer, drag,
  wheel, resize, and focus forwarding without leaking input to Studio.
- [x] Make the Neovim overlay the exclusive input owner so forwarded keys such
  as `D`, `F`, `G`, `P`, Cmd/Ctrl-O, Cmd/Ctrl-S, and F3 cannot also trigger
  Rayslides shortcuts in the same frame.
- [x] Prefer backend-produced committed Unicode for plain, AltGr, Option, and
  non-US layout text while retaining physical mappings for modified shortcuts.
- [x] Install controlled `acwrite` buffer callbacks and the synchronous host
  apply response needed by `:wq`.
- [x] Cover `:w`, `:wq`, `:x`, `ZZ`, clean/dirty `:q`, `:q!`, `ZQ`, `:qa!`,
  buffer/window closure, EOF, crash, and host shutdown with integration tests.
- [x] Update the accepted revision after every successful write so a later
  forced quit retains accepted transactions and discards only newer edits.
- [x] Verify every overlay-close path restores Studio focus/input exactly once.

Exit gate: every row in the lifecycle table behaves identically through Vim
commands, equivalent key sequences, and Rayslides overlay controls.

### 3. Whole-document source editor

- [x] Add a parser-derived private Vim runtime with `.sld` filetype detection,
  conventional colorscheme-linked syntax groups, minimal comment settings,
  focused `synID` assertions, and a parseable-deck syntax sweep.
- [x] Prepend the private runtime in embedded sessions and set scratch buffers
  to `filetype=rayslides` without replacing the user's configuration.
- [x] Add a discoverable Studio **Edit source in Neovim** command and shortcut and
  populate the buffer from the exact in-memory document revision.
- [x] Apply valid source as one guarded Studio transaction; preserve
  selection/current slide where identity permits and keep existing save/dirty/
  external-change protections intact.
- [x] Reject invalid, oversized, stale, or non-UTF-8 candidates atomically and
  publish precise line diagnostics into Neovim.
- [x] Test no-op, ordinary LF, CRLF+BOM, missing final newline, mixed endings,
  large documents, invalid intermediate source, repeated writes, undo/redo,
  save/reopen, and discard-after-write.

Exit gate: an author can edit a complete real deck, write repeatedly, recover
from parser errors in place, quit with or without applying, then use ordinary
Studio undo/save/reopen with byte-preserving results.

### 4. Expanded Studio field editors

- [x] Replace or augment eligible `...` text, bullets, and speaker-note modal
  paths with the same overlay host while retaining the built-in prompt as
  fallback.
- [x] Preserve live inline drafts, edit scope, semantic validation, selection,
  prompt overflow behavior, and one-entry history semantics.
- [x] Give each buffer an appropriate name/filetype and initial cursor/selection
  without allowing one field session to leak contents or undo into another.
- [x] Cover direct, shared template, local instance, morph state, multiline
  bullets, notes, no-op, invalid semantic value, process crash, and runtime
  fallback cases.

Exit gate: every eligible expanded field is faster to reopen with Neovim and
produces exactly the same guarded source patches as its built-in counterpart.

### 5. Linux release-quality pass

- [x] Exercise normal config and `--clean`; handle missing/incompatible child
  exits, slow or plugin-broken startup, bounded noisy stderr, child crash,
  repeated open/close, and application shutdown without hangs, zombies, or
  source loss.
- [x] Verify common Linux Neovim installations and PATH layouts without adding
  a compile-time system-Neovim dependency.
- [x] Verify bounded grids/snapshots and record steady-frame, resize,
  startup/open-close, and parser-memory data on a large `.sld` deck.
- [x] Document build flags, runtime discovery, recovery mode, write-vs-disk-save
  semantics, lifecycle commands, limitations, and troubleshooting.

Exit gate: enabled support is safe as the Linux default, while
`-Dneovim=false` and runtime fallback retain the current editor experience.

### 6. macOS portability and packaging

- [x] Discover configured/PATH, Homebrew Apple Silicon/Intel, MacPorts, and
  common user-local Neovim installations from a Finder-launched `.app`.
- [ ] Verify Command/Option key mappings, Retina scaling, focus, clipboard,
  Unicode input, resize, process teardown, and app quit.
- [x] Package the private syntax runtime and monospace font into the app bundle
  without bundling Neovim itself.
- [ ] Run the enabled/disabled build matrix and a copied-bundle visual/editor/
  write/quit QA pass outside the checkout.

Exit gate: the same deck and lifecycle matrix passes from the packaged macOS
application, and a missing Neovim installation falls back cleanly.

### 7. Optional follow-ups after the vertical feature ships

- [ ] Debounced live slideshow preview that only publishes valid intermediate
  parses and retains the last valid graph during syntax errors.
- [ ] User-configurable editor executable, arguments, font, size, and clean
  mode through a stable Rayslides configuration surface.
- [ ] Richer parser diagnostics, buffer-local completion, help lookup, and
  source-navigation commands implemented without requiring a global plugin.
- [ ] Evaluate multigrid, IME pre-edit support, dynamic font fallback, and
  Tree-sitter only against reproduced limitations in the shipped one-grid
  implementation.

## Explicitly out of scope for the initial feature

- Linking or shipping `libnvim` inside the Rayslides process.
- Running Neovim in a PTY or parsing terminal escape sequences.
- Attaching to arbitrary user-owned Neovim sockets or servers.
- Bundling the Neovim executable or a plugin manager.
- Windows support, external multigrid windows, native OS child windows, remote
  collaborative editing, or replacing every one-line numeric/path control.
- Allowing Neovim to write the `.sld` file behind Studio's save, conflict,
  recovery, and history boundaries.

## Completion definition

The feature is complete when a supported build can open either the entire
document or every eligible expanded field in a faithful raylib Neovim grid;
type, paste, scroll, resize, and use the mouse; apply valid edits atomically;
recover from invalid edits; close through all normal Vim write/quit commands;
survive a child failure; undo and save through Studio; and fall back without
data loss when support is disabled or Neovim is unavailable.

Every completed tranche must update its checkboxes and add concise dated
evidence here so build/runtime behavior cannot drift from this contract.

## Progress record

- 2026-09-01: Research and a local Neovim 0.12.5 protocol probe confirmed the
  external-UI architecture: attach a 40x10 line grid, receive real redraw and
  highlight events, send normal-mode input, read the edited buffer back, and
  exit/reap cleanly. Product direction, compile-time opt-out, one-grid MVP,
  guarded source application, and write/quit semantics were accepted.
- 2026-09-01: Tranche 0 shipped behind an experimental default-off
  `-Dneovim` boundary. Disabled builds select a dependency-free stub; enabled
  builds lazily compile pinned MIT-licensed MPack 1.1.1. The bounded streaming
  scanner and RPC codec cover fragmentation, concatenation, every MessagePack
  scalar/container/extension family, unknown values, malformed data, and
  resource limits. `zig build -Dneovim=true neovim-probe` now performs the
  complete attach/redraw/input/buffer-read/child-reap round trip in Zig.
- 2026-09-01: A parser-grounded private `.sld` Vim runtime landed early. It
  overrides Neovim's stock `.sld` Scheme association, highlights the real
  directive/attribute/value/inline-markup grammar through conventional groups,
  and passes exact headless `synID` assertions plus all repository deck loads.
- 2026-09-01: The Linux whole-source vertical slice is operational. A heap-owned
  host runs `nvim --embed` over bounded MessagePack-RPC pipes, publishes immutable
  line-grid snapshots, and renders the modal overlay on raylib's main thread.
  Studio exposes the editor through its Commands palette and Cmd/Ctrl-E. The
  synchronous `acwrite` bridge applies only parser-valid candidates through the
  existing Studio history/dirty boundary. A live Neovim 0.12.5 probe verifies
  redraw, `:w`, clean `:q`, rejected `:wq`, dirty `:q`, and forced `:q!`; GUI QA
  verified syntax rendering, `ZQ` discard, and `ZZ` apply-and-close without a
  disk write. The enabled suite passes 619/619 tests and the private syntax
  runtime passes every 26 checked repository decks.
- 2026-09-01: The Linux initial feature gate completed. Exact-source formatting
  now preserves BOM, LF/CRLF/mixed separators, and final-newline state across
  accepted writes; parser/UTF-8/size failures stay inside Neovim with line
  diagnostics. Expanded text, multiline bullet, and speaker-note editors reuse
  the same guarded semantic command path and retain the built-in fallback. The
  lifecycle probe covers `:w`, every documented quit variant, repeated writes,
  field buffers, focus transitions, child failure, and exact-child reaping.
  JetBrains Mono 2.304 and its OFL are lazy enabled-build resources. Three
  deterministic `--clean` overlay baselines pass at 900×506, 1600×900, and
  2560×1440; the Linux harness verified each exact window as floating before
  capture. Live normal-config GUI QA kept `f` and `D` inside Neovim with the
  host window still floating and non-fullscreen. Enabled tests pass 629/629,
  disabled tests pass 607/607, and the standalone syntax sweep remains green.
- 2026-09-01: macOS build/runtime seams are ready for native validation. Finder
  launches can discover PATH, Apple Silicon/Intel Homebrew, MacPorts,
  user-local, mise, and asdf Neovim paths; enabled app bundles copy the private
  runtime, JetBrains Mono, and its license without bundling Neovim. Native
  Command/Option/Retina/focus/clipboard QA and a copied-bundle enabled/disabled
  matrix remain explicitly unchecked because they require a macOS host.
