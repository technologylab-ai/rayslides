# Agent handoff: replace a slide placeholder with a live camera

Update the target Rayslides `.sld` slide so its existing visual placeholder
becomes a live camera item. Preserve the placeholder's `id=`, `x=`, `y=`,
`w=`, `h=`, `fit=`, focal position, `rotation=`, opacity, ordering, reusable
ownership, and morph-state semantics unless the surrounding design clearly
requires a change.

If the placeholder is an image, reuse that image as the stopped/export poster:

```text
# Before
@box id=presenter img=assets/presenter-placeholder.png x=520 y=180 w=880 h=560 fit=cover rotation=-12

# macOS replacement
@box id=presenter cam=0 video_size=1920x1080 poster_image=assets/presenter-placeholder.png x=520 y=180 w=880 h=560 fit=cover rotation=-12

# Linux replacement (confirm the actual USB device first)
@box id=presenter cam=/dev/v4l/by-id/USB_CAMERA_ID video_size=1280x720 poster_image=assets/presenter-placeholder.png x=520 y=180 w=880 h=560 fit=cover rotation=-12
```

If the placeholder is not an image, keep or create a suitable PNG/JPEG poster
and set it with `poster_image=`. Do not use numeric `poster=` for a camera;
cameras are live and non-seekable. `video_size=` is the capture mode, while
`w=`/`h=` are the on-slide display size.

Validation checklist:

- Parse/build the deck and ensure the target item remains a video object.
- Confirm the poster appears in Studio, thumbnails, and passive/export views.
- Enter presentation, hover the item, and use the pill's Play and Stop buttons.
- Confirm Stop releases the camera and restores the poster.
- Confirm fitting, crop/focus, rotation, opacity, and any morph state still work.
- On macOS, test with the bundled `zig-out/Rayslides.app`; allow the camera
  permission prompt and retry Play once if the first start times out.
- On Linux, run `v4l2-ctl --list-devices`, select the intended USB camera rather
  than the built-in webcam, prefer `/dev/v4l/by-id/...`, and verify that the
  authored `video_size=` is a supported mode.
