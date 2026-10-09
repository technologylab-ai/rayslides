# Zig 0.17.0 migration evidence

Rayslides now requires exact Zig 0.17.0 and consumes the official immutable
raylib-zig 0.17 port. The complete application, built-in editor, optional embedded
Neovim editor, and macOS packaging compile with safety checks enabled. Native
macOS test, Neovim protocol, and actual application framebuffer gates pass.
The Retina startup fix restores correct Studio and editor geometry. Framebuffer
qualification remains separate from compilation and headless protocol evidence.

## Source graph and representation audit

The application baseline is `630948d4bce9139679832a95dbdc229b597d51a1`.
The new raylib-zig pin is
[`50d450099da664bedd7dcc6ed40204ab0bb861a5`](https://github.com/raylib-zig/raylib-zig/commit/50d450099da664bedd7dcc6ed40204ab0bb861a5),
with package hash `raylib_zig-6.0.0-KE8REDSmBQAbyUv_Fh71wgvhQSP2zsmVxtPRLzCgIXWK`.
Its C implementation identifies itself as raylib 6.1-dev, although its Zig
package version remains 6.0.0. It pins raylib
`2dee47282ae75d241759cc35f22e4768dcd092be` and raygui
`9cb5cfa73290ba920d071f57c1d06a4daee22f52`.
The existing MPack 1.1.1 and JetBrains Mono 2.304 commits and hashes are retained.
No upstream dependency source is patched by this application.

The exact compiler source defines the port; the
[wiki migration guide](https://github.com/technologylab-ai/zigllmwiki/blob/main/docs/zig-0.16-to-0.17-migration.md)
provides pinned guidance and representation checks.

- Five removed `@cImport` sites become target-specific `b.addTranslateC` modules.
  The MPack binding-only pragma workaround is preserved in a C header; its
  separately compiled C implementation keeps normal compiler macros.
- Enum reflection uses names, preserving the original enum values with
  `@field`. Enum counts still size the same indexed storage.
- Array repetition becomes typed `@splat`. The repeated speaker-notes fixture
  remains a borrowed byte slice over arrays of `u8`, without inter-element
  padding or an unintended sentinel contract.
- Removed allocation and formatting helpers retain their explicit zero
  sentinel using `dupeSentinel` and `std.mem.printSentinel`.
- The renderer's scalar float cast retains IEEE-754 value bits. A literal
  `1.0 -> 0x3f800000` / `-0.0 -> 0x80000000` oracle checks its fingerprint path.
  The signed scalar MessagePack cast retains two's-complement byte meaning;
  the existing RPC test checks independently specified compact integer bytes.
- The new raygui message box returns an activation result separately from the
  selected button. Only `Result.pressed` dismisses it; accepting every
  non-negative result would silently dismiss a still-open dialog.
- Passthrough arguments, lazy font-path options, transitive lazy SDK handling,
  and generated package output paths use the 0.17 build contracts.

## Native macOS correctness

Development checks ran on 2026-10-09 on Apple M3 Max / aarch64, macOS 26.6.2
(build 25G83), with the checksum-verified official aarch64-macos Zig 0.17.0
archive. The macOS deployment floor remains 13.0; that floor is compile/link
metadata, not runtime evidence for macOS 13. Neovim is 0.12.5. The Python harness
uses an isolated Python 3.12 environment with Pillow 12.3.0.

The host reservation followed the wiki's cooperative protocol: pre-existing
process inspection, atomic acquisition of `/tmp/zig-http-measurement.lock`,
unique owner metadata, and retention through workload and child cleanup.
No benchmark or throughput comparison ran. Builds used `-j2`; correctness used
Debug and Safe, and all attempted graphics captures used Safe. The existing
opt-in baseline harness also checks its historical capture-timing thresholds;
that check is not an application performance claim.

| Gate | Observed result |
| --- | --- |
| Complete application + built-in editor, Debug/Safe | 631 application tests and 1 stub test pass |
| Complete application + embedded editor, Debug/Safe | 631 application tests and 23 editor tests pass |
| Live Neovim embed/session probes, Debug/Safe | Grid rendering protocol, edits, quit/apply fidelity, child failure and host reaping pass |
| Neovim syntax runtime | 26 real decks pass |
| Studio baseline harness | Comparator/schema self-test passes |
| CLI | Real executable version/help exit successfully |
| macOS app bundles | Built-in and embedded editor packages build with Safe |
| Actual application framebuffers | Hidden 900×506 Studio and Neovim captures pass nonblank, 4-slide render-state, and clean-exit checks; actual Safe bundle passes too |
| Historical compact visual reference | Capture succeeds; pixel comparison fails (details below), references retained |

Run the local correctness matrix with the exact compiler and Python Pillow on
`PATH`:

```sh
zig build verify -Doptimize=debug -Dneovim=false -j2 --summary all
zig build verify -Doptimize=safe -Dneovim=false -j2 --summary all
zig build verify neovim-probe neovim-runtime-test -Doptimize=debug -Dneovim=true -j2 --summary all
zig build verify neovim-probe neovim-runtime-test macos-app -Doptimize=safe -Dneovim=true -j2 --summary all
```

## Graphics and startup boundaries

The Mac console was locked (`CGSSessionScreenIsLocked=Yes`). GLFW excludes
sleeping displays. The first 0.17 capture could not find a primary monitor and
aborted when application code called a window operation after failed startup.
A matched Safe build of the exact application baseline with exact Zig 0.16.0
also failed display initialization, then crashed during old cleanup.
The port returns an ordinary `WindowInitializationFailed` error before those
window operations and cleanup become eligible.

A scoped `caffeinate -du` made display initialization succeed for both versions,
but hidden and visible capture attempts still produced blank framebuffers in
the locked session. LaunchServices did not produce a successful capture either.
The user then unlocked the Mac; the session flag was rechecked before testing.
Both the unmodified 0.16 baseline and the initial port still showed broken
geometry/readback. Those first failures are retained; no oracle was weakened.
They identify a baseline application problem, rather than proving a new
compiler or dependency regression.

Source inspection also found that diagnostics read the back buffer after
`EndDrawing` had swapped it; the buffer contents are then undefined. The port
flushes and copies the completed framebuffer before the swap, retains that
owned CPU image through the unchanged post-edit readiness gate, and releases it
on skips, errors, and exit. Source edits and resource rebuilds remain outside
the acquired draw frame. This change alone did not restore Mac capture.

The application also left `FLAG_WINDOW_HIGHDPI` disabled while resizing Cocoa
windows. Independent Safe probes verified literal red/white pixels and coherent
logical/render dimensions for both high- and low-DPI windows; the basic C ABI,
color and image-return paths work. Enabling `window_highdpi` on macOS makes
raylib keep Retina logical coordinates and backing framebuffer pixels coherent
through the application's resize path. This restores the complete Studio
geometry and nonblank capture. The actual application and its Safe bundle now
pass 900×506 Studio and real embedded-Neovim framebuffer checks on the Apple M3
Max GPU, with clean exit. The screenshot is normalized from Retina backing
pixels to the requested logical dimensions.

The existing `compact-properties` reference comparison remains a failed,
separately scoped gate: mean channel delta 2.082, RMS 9.557, and 5.32% changed
pixels (3% limit). The current frame includes the Notes toolbar control absent
from that older reference and uses Retina rasterization. The complete geometry
was visually inspected, but the references and thresholds were not changed.
Passing nonblank/current-frame checks does not claim a pixel match to that
historical image. Full historical visual-suite requalification remains pending.

The native CI matrix builds and tests Debug/Safe on Linux, macOS, and Windows,
with the optional editor on Linux/macOS. Its Safe Linux Xvfb gate exercises a
real Mesa software-rendered application framebuffer and the Neovim overlay,
with a separate no-display startup gate. Hosted evidence is recorded separately
when those runs finish. Cross-compilation is not used as runtime evidence.
Camera capture, audio/video hardware, and physical multi-monitor handoff have
not been newly qualified here. The native Mac framebuffer result covers the
named generated Studio/editor scenes, not every application UI state.
