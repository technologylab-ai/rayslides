# Zig 0.17.0 migration evidence

Rayslides now requires exact Zig 0.17.0 and consumes an immutable relay of the
official raylib-zig 0.17 port with a minimal upstream Windows SDK build fix. The complete application, built-in editor, optional embedded
Neovim editor, and macOS packaging compile with safety checks enabled. Native
macOS test, Neovim protocol, and actual application framebuffer gates pass.
The Retina startup fix restores correct Studio and editor geometry. Framebuffer
qualification remains separate from compilation and headless protocol evidence.

## Source graph and representation audit

The application baseline is `630948d4bce9139679832a95dbdc229b597d51a1`.
The official raylib-zig 0.17 baseline is
[`50d450099da664bedd7dcc6ed40204ab0bb861a5`](https://github.com/raylib-zig/raylib-zig/commit/50d450099da664bedd7dcc6ed40204ab0bb861a5).
The final wrapper pin is the manifest-only relay
[`5e4bf359bcf958884289ec165fd89261937d8f1b`](https://github.com/renerocksai/raylib-zig/commit/5e4bf359bcf958884289ec165fd89261937d8f1b),
with hash `raylib_zig-6.0.0-KE8REDimBQDOsYOJkaDz88hsBpTsBb1DRENZ2OU_yKua`.
It selects the C raylib SDK-link fix
[`89f86afe0fef6f2d0f684313fd58af0c85ce7a4c`](https://github.com/renerocksai/raylib/commit/89f86afe0fef6f2d0f684313fd58af0c85ce7a4c)
(hash `raylib-6.0.0-whq8uCmfNwWMzHMDK29Wxfg0cSg1myyFGFDJakT1fQv_`), based on
official `2dee47282ae75d241759cc35f22e4768dcd092be`.
That owning-dependency change disables pkg-config for four native Windows SDK
libraries; no runtime or binding code changes. Upstream review is tracked in
[raylib #6242](https://github.com/raysan5/raylib/pull/6242) and the
[wrapper relay #363](https://github.com/raylib-zig/raylib-zig/pull/363).
The C implementation identifies itself as raylib 6.1-dev, although its Zig
package version remains 6.0.0. Raygui remains pinned to
`9cb5cfa73290ba920d071f57c1d06a4daee22f52`.
The existing MPack 1.1.1 and JetBrains Mono 2.304 commits and hashes are retained.
Dependency fixes remain in their owning repositories; this application consumes their immutable hashes.

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
| Complete application + built-in editor, Debug/Safe | 632 application tests and 1 stub test pass |
| Complete application + embedded editor, Debug/Safe | 632 application tests and 23 editor tests pass |
| Live Neovim embed/session probes, Debug/Safe | Grid rendering protocol, edits, quit/apply fidelity, child failure and host reaping pass |
| Neovim syntax runtime | 26 real decks pass |
| Studio baseline harness | Comparator/schema self-test passes |
| CLI | Real executable version/help exit successfully |
| macOS app bundles | Built-in and embedded editor packages build with Safe |
| Actual application framebuffers | Hidden 900×506 Studio and Neovim captures pass nonblank, 4-slide render-state, and clean-exit checks; actual Safe bundle passes too |
| Retina fullscreen transitions | Exclusive requests use effective borderless mode on macOS; geometry, scissor and input checks pass through entry, picker confirmation/cancellation and window restoration |
| Historical compact visual reference | Obsolete UI reference; capture succeeds and comparison is recorded separately below |

Run the local correctness matrix with the exact compiler and Python Pillow on
`PATH`:

```sh
zig build verify -Doptimize=debug -Dneovim=false -j2 --summary all
zig build verify -Doptimize=safe -Dneovim=false -j2 --summary all
zig build verify neovim-probe neovim-runtime-test -Doptimize=debug -Dneovim=true -j2 --summary all
zig build verify neovim-probe neovim-runtime-test macos-app -Doptimize=safe -Dneovim=true -j2 --summary all
```

## Windows SDK, tooling, paths, and save ownership

The first native Windows gate passed 626 application tests and exposed five
failures: three path-fixture mismatches and two Save As failures. Native SDK
links now bypass pkg-config in both the application and the owning C dependency,
so Strawberry Perl's broken batch wrapper is not involved. Windows development
tooling uses the selected `python` interpreter, keeping Pillow in the same
isolated environment; `-Dpython` permits an explicit Python 3 path.

Authored Windows media references use portable forward slashes in `.sld`
source, while browser filesystem fixtures compare native separators. The
exclusive Save As reservation requests read access so exact Zig 0.17's Windows
`FILE_ALL_INFORMATION` stat query can inspect its identity. Exclusivity and the
identity/version checks remain intact.

Review also found a pre-existing data-preservation defect: after the atomic
writer detected a changed source, outer error cleanup deleted the now-foreign
pathname. The detected-conflict path now retains it. A deterministic regression
replaces the actual closed reservation during the writer's first allocation,
requires `SourceChangedOnDisk`, and verifies the external replacement bytes
remain. Ordinary allocation failure still removes an unchanged reservation.
This protects detected conflicts; the existing compare/rename gap does not
provide atomic isolation from every uncooperative concurrent writer.

## Neovim probe ordering and compatibility

The first hosted Ubuntu job installed Neovim 0.9.5. Its default and embedded
unit suites passed, but a live probe returned the correct revision with the
original source instead of a just-queued edit. The
[exact 0.9.5 API documentation](https://github.com/neovim/neovim/blob/v0.9.5/runtime/doc/api.txt#L1046)
specifies asynchronous processing for `nvim_input`. Sending an independent
`nvim_command("write")` or `"wq"` immediately afterward did not establish that
the edit had run. This was a probe-ordering defect, not evidence of source
encoding loss or a Zig compiler regression.

The probes now queue edits and their typed `:w`, `:wq`, `:x`, `ZZ`, and dirty
`:qa` commands through the same input stream. Literal expected source and
revision assertions remain unchanged. Typed rejected writes can display a
hit-enter prompt, so the dirty-quit and forced-discard probes acknowledge it
before their next typed command, as the existing compact field-editor probe
already did. The child-failure probe uses `vim.uv or vim.loop` for the renamed
libuv namespace. No production editor code or supported minimum version was
changed. Corrected live probes pass on the local Mac in Debug and Safe; hosted
Linux results qualify the older version separately.

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

Independent PR review then found that raylib's macOS exclusive-fullscreen path
reports DPI 1 while retaining a Retina framebuffer. A native reproduction drew
the corner markers correctly but clipped the lower-right scissor marker away.
On macOS, requested exclusive fullscreen now selects and records effective
borderless mode, keeping drawing, mouse and scissor coordinates coherent.
Shift+F and display-picker restoration use that same policy. Linux and Windows
retain exclusive fullscreen. The reference and macOS release QA document the
platform behavior.

The bounded in-app diagnostic qualifies both exclusive and borderless requests
on the M3 Max with a 2× LG HDR 4K display. Five stages pass: windowed, fullscreen,
picker confirmation, picker cancellation and restored window. Logical dimensions
are 900×506 windowed and 3840×2160 fullscreen; backing framebuffers are 1800×1012
and 7680×4320, with DPI 2 throughout. Geometry, input coordinates and clipped
drawings pass, and an independent nine-pixel PNG oracle checks corner colors,
the scissor marker and four pixels outside the clip. The owned window restores
and exits cleanly. Debug and Safe verification still pass all 632 application
tests; the existing Studio framebuffer smoke also passes after the change.

The checked-in `compact-properties` image is an obsolete UI reference. It was
last refreshed by `682ad87` on 2026-08-25, before `630948d` added the Notes UI on
2026-09-11, while the application still used Zig 0.16. The Notes toolbar control
shifts the existing controls; the current Retina capture also differs in text
and edge rasterization. Comparing against that historical image reports mean
channel delta 2.082, RMS 9.557, and 5.32% changed pixels (3% limit). That result
records disagreement with the old reference rather than establishing a port
regression. The complete current geometry was visually inspected and the named
framebuffer checks above pass. Historical references and thresholds are retained;
refreshing the visual suite requires reviewing each affected current scene before
promoting new images, as described in `tests/studio_baselines/README.md`.

The native CI matrix builds and tests Debug/Safe on Linux, macOS, and Windows,
with the optional editor on Linux/macOS. Its Safe Linux Xvfb gate exercises a
real Mesa software-rendered application framebuffer and the Neovim overlay,
with a separate no-display startup gate. Hosted evidence is recorded separately
when those runs finish. Cross-compilation is not used as runtime evidence.
Camera capture, audio/video hardware, and physical multi-monitor handoff have
not been newly qualified here. The native Mac framebuffer result covers the
named generated Studio/editor scenes, not every application UI state.
