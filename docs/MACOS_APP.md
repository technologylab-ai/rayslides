# Rayslides for macOS

The macOS application bundle is an additive convenience for Finder users. It
does not replace the normal command-line build and does not introduce another
document format.

## Build

From the repository root:

```sh
zig build -Doptimize=ReleaseSafe macos-app
```

The result is `zig-out/Rayslides.app`. The completed directory receives only a
local ad-hoc seal so Apple Silicon regards its executable, plist, and resources
as one internally valid app. It is not Developer-ID-signed or notarized, and no
certificate, signing identity, Apple developer account, or network service is
required. On a Mac that did not build it, right-click the app and choose
**Open** once if Gatekeeper declines the first double-click.

The build embeds version metadata, an `.sld` document declaration, and an
`.icns` generated from the existing Studio light-sculpture artwork. Its binary
targets macOS 13 or newer. The architecture follows the selected Zig target;
the ordinary native build on an Apple Silicon Mac is therefore arm64.

## Open decks

- Double-click a `.sld` after selecting Rayslides as its application.
- Choose **Open With → Rayslides** in Finder.
- Drop one or more files onto a running Rayslides window. The first `.sld` is
  opened; unrelated file types are ignored with an explanation.
- Continue using `zig-out/bin/rayslides deck.sld` in Terminal exactly as on
  Linux and Windows.

Finder document events and cross-platform window drops enter the same
transactional loader used by the CLI. A parser-invalid replacement keeps the
current deck open. Rayslides also refuses to replace meaningful unsaved Studio
work or an active inline/modal draft.

The bundle starts with the home directory as its neutral working directory.
It changes to the opened deck's directory when loading that deck, so relative
fonts and images continue to resolve without requesting access to the entire
Documents folder.

## Save and recovery locations

- A named, writable deck saves normally to its source path.
- **Save Copy** and quit recovery first create a unique
  `NAME.edited.sld`, `NAME.edited-2.sld`, and so on beside a named source.
- If a named source directory is not writable, the macOS app falls back to
  `~/Library/Application Support/Rayslides/Recovery` and retains the source
  basename.
- An untitled macOS app document recovers into that same Application Support
  directory.
- An untitled direct CLI session retains the historical behavior and recovers
  into the process's current working directory.

Rayslides never silently discards a dirty source buffer: if it cannot write a
recovery copy, quitting is cancelled and the document stays open.
