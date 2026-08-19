# Studio visual and performance baselines

These references exercise four deterministic ReleaseSafe Studio scenarios:

- `compact-properties` — 900×506 docked Properties and selected object;
- `default-command-palette` — 1600×900 searchable command discovery;
- `large-precision` — 2560×1440 rulers, guides, safe areas, and Inspector;
- `incremental-160` — 1600×900 after one real source edit rebuilds 1/160
  slides.

Each PNG is normalized to the requested logical client size. Its JSON partner
records render mode/count/timing, frame sampling, Studio cache activity, deck
size, active item/fragments, and parser-arena capacity. The startup banner and
diagnostics HUD are intentionally hidden; the exercised Studio surfaces are
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

Run one scenario with, for example:

```sh
zig build -Doptimize=ReleaseSafe studio-baselines -- \
  --workspace 12 --scenario compact-properties
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

An update first validates exact image dimensions, scenario/deck identity,
rebuild mode, slide counts, and incremental full/partial event counts. Invalid
captures are never promoted to baselines.

The image comparator tolerates minor GPU/font rasterization variation: mean
absolute channel error ≤2.5, RGB RMS ≤10, and at most 3% of pixels may differ
by more than 12 in any channel. Performance fails above the larger of 2× the
full baseline or +5 ms; the partial threshold is 2.5× or +2 ms. This suite is
opt-in because those timings and rasterized glyphs remain machine-sensitive.
