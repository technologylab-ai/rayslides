# Noto Emoji subset

`NotoEmoji.ttf` is a glyph subset of Google Fonts' monochrome Noto Emoji
variable font:

- Source: <https://github.com/google/fonts/blob/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf>
- Original SHA-256: `de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551`
- License: [SIL Open Font License 1.1](./NotoEmoji-OFL.txt)

The subset contains exactly the presentation glyphs listed in
`emoji_fontchars` in [`../fonts.zig`](../fonts.zig). It was generated with
fonttools `pyftsubset`, retaining layout features, glyph names, and font-name
metadata. No glyph outlines were modified.
