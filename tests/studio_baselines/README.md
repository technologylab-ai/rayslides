# Studio visual and performance baselines

These references exercise ten deterministic ReleaseSafe Studio scenarios plus
three opt-in embedded-Neovim overlay scenarios. The first four use the
generated stress deck; the Motion scenarios open the fixture deck
`testslides/studio-motion-qa.sld` (4 slides) instead:

- `compact-properties` — 900×506 docked Properties and selected object;
- `default-command-palette` — 1600×900 searchable command discovery;
- `large-precision` — 2560×1440 rulers, guides, safe areas, and Inspector;
- `incremental-160` — 1600×900 after one real source edit rebuilds 1/160
  slides;
- `compact-motion` — 900×506 Motion inspector for the `click_bullets` reveal,
  with the narrow transport (Play/Stop only);
- `default-timeline` — 1600×900 slide 2 shown through reveal step 2 with the
  `auto_bullets` BUILD card selected and canvas step badges;
- `default-preview` — 1600×900 slide 3 live preview paused at 1.5 s
  (TAKEOVER state, scrubber and time readout);
- `large-motion` — 2560×1440 Motion inspector for `click_bullets`;
- `large-morph-ghosts` — 2560×1440 slide 3 EXPLAIN state with `title`
  selected: State section, change list, and morph ghosts/paths on the canvas;
- `compact-transition` — 900×506 slide 2 Transition section via the timeline
  `IN` chip.

An enabled build also provides `neovim-compact`, `neovim-default`, and
`neovim-large` at 900×506, 1600×900, and 2560×1440. They start Neovim with
`--clean`, wait for a real external-UI grid snapshot, and verify the overlay's
clipping, cell geometry, private URI, syntax colors, and bundled JetBrains Mono
font without depending on the capture machine's `init.lua`.

Each PNG is normalized to the requested logical client size. Its JSON partner
records render mode/count/timing, frame sampling, Studio cache activity, deck
size, active item/fragments, and parser-arena capacity. The diagnostics HUD is
intentionally hidden; the exercised Studio surfaces are
otherwise the real application UI.

## Run

Install Python Pillow, build ReleaseSafe, and compare against the approved
references:

```sh
zig build -Doptimize=ReleaseSafe studio-baselines -- --workspace 12
```

On macOS with Aerospace, `--workspace 12` is a strict contract. The harness
identifies the launched process window, moves it, makes it floating, queries
its window ID/workspace/layout, and only then opens the application's capture
gate. Failure to prove all three aborts the scenario without a screenshot.
Every successful scenario exits by itself. Omit `--workspace` on systems that
do not use Aerospace.

Under Hyprland the harness identifies the exact launched Rayslides PID,
switches that window to floating once, verifies `floating=true`, and only then
opens the capture gate. This keeps Linux captures non-tiling without changing
the user's window rules.

Run one scenario with, for example:

```sh
zig build -Doptimize=ReleaseSafe studio-baselines -- \
  --workspace 12 --scenario compact-properties
```

Run the separate Neovim suite only from an enabled build:

```sh
zig build -Dneovim=true -Doptimize=ReleaseSafe neovim-baselines
```

Actual PNGs/JSON, process logs, and amplified failure diffs are written to
`zig-out/studio-baselines`. The lightweight comparator itself is covered by:

```sh
zig build studio-baseline-test
```

## Update

Only replace references after visually reviewing every affected scenario and
confirming that a performance increase is intentional:

```sh
zig build -Doptimize=ReleaseSafe studio-baselines-update -- --workspace 12
```

The corresponding opt-in editor update step is
`zig build -Dneovim=true -Doptimize=ReleaseSafe neovim-baselines-update`.

An update first validates exact image dimensions, scenario/deck identity,
rebuild mode, slide counts, and incremental full/partial event counts. Invalid
captures are never promoted to baselines.

The image comparator tolerates minor GPU/font rasterization variation: mean
absolute channel error ≤2.5, RGB RMS ≤10, and at most 3% of pixels may differ
by more than 12 in any channel. Performance fails above the larger of 2× the
full baseline or +5 ms; the partial threshold is 2.5× or +2 ms. This suite is
opt-in because those timings and rasterized glyphs remain machine-sensitive.
