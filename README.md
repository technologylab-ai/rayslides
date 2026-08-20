# Rayslides

Design visually. Keep readable source. Present without the cloud.

[![Rayslides Studio editing a polished slide](docs/images/rayslides-studio-properties.jpg)](https://technologylab-ai.github.io/rayslides/)

Rayslides is a visual slide editor and presenter built with Zig and
[raylib](https://github.com/raysan5/raylib). Edit a deck on the canvas or in its
plain-text `.sld` source. Both views stay in sync.

With Rayslides, you can:

- edit slides directly and reuse items;
- add reveals, transitions, and semantic morph states;
- read private notes and control a deck from a phone;
- run Crowdplay polls on the local network;
- save PNG screenshots and export a PDF; and
- build native programs for macOS, Linux, and Windows.

## Get started

Rayslides requires Zig 0.16.x. The minimum version is Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseSafe
zig-out/bin/rayslides
```

Run the program without a file to open Studio's new-deck chooser. Use
`--studio` to edit an existing deck:

```sh
zig-out/bin/rayslides --studio talk.sld
```

During development, use `zig build run -- talk.sld`. On macOS,
`zig build -Doptimize=ReleaseSafe macos-app` also creates
`zig-out/Rayslides.app`.

## Documentation

- [Explore the visual guide](https://technologylab-ai.github.io/rayslides/)
- [Create your first deck](https://technologylab-ai.github.io/rayslides/getting-started.html)
- [Learn the Studio interface](https://technologylab-ai.github.io/rayslides/studio.html)
- [Add reveals, transitions, and morph states](https://technologylab-ai.github.io/rayslides/motion.html)
- [Write `.sld` source](https://technologylab-ai.github.io/rayslides/format.html)

Rayslides began as a raylib-based port of
[renerocksai/slides](https://github.com/renerocksai/slides). It now combines
visual editing with its text-based foundation.
