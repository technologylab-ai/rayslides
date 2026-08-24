#!/usr/bin/env python3
"""Capture the real Studio surfaces used by the documentation.

The app owns each deterministic framebuffer capture. This wrapper supplies the
documentation fixture/state, isolates every macOS window on the requested
Aerospace workspace, and writes review artifacts outside docs/images. Promote
only captures that have been visually reviewed.
"""

from __future__ import annotations

import argparse
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from studio_baseline import (
    ROOT,
    aerospace_windows_for_pid,
    assert_frame_not_blank,
    place_and_verify_window,
    terminate_process,
)


CAPTURE_ATTEMPTS = 4
INTER_CAPTURE_PAUSE = 1.5
RETRY_PAUSE = 3.0


@dataclass(frozen=True)
class Capture:
    name: str
    width: int
    height: int
    deck: str | None
    extra_args: tuple[str, ...] = ()
    settle_frames: int = 120


CAPTURES: tuple[Capture, ...] = (
    Capture(
        "overview-properties",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-select=headline",),
    ),
    Capture("overview-objects", 2560, 1440, "testslides/studio-showcase.sld"),
    Capture(
        "rotated-image",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-select=art_image",),
    ),
    Capture(
        "command-palette",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-command-palette",),
    ),
    Capture(
        "showtime",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-showtime",),
        180,
    ),
    Capture(
        "media-playback",
        2560,
        1440,
        "testslides/studio-media-authoring.sld",
        ("--diagnostics-select=hero_video", "--diagnostics-video-playback"),
        180,
    ),
    Capture(
        "library-preview",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-library-preview=feature_panel",),
    ),
    Capture(
        "library-definition",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        (
            "--diagnostics-library-definition=feature_panel",
            "--diagnostics-select=__studio_preview_0.title",
        ),
    ),
    Capture(
        "motion-studio",
        2560,
        1440,
        "testslides/docs-motion.sld",
        ("--diagnostics-select=title",),
    ),
    Capture(
        "status-drawer",
        2560,
        1440,
        "testslides/studio-showcase.sld",
        ("--diagnostics-select=headline", "--diagnostics-status-drawer"),
    ),
    Capture("new-deck", 2560, 1440, None),
)


def capture_map() -> dict[str, Capture]:
    return {capture.name: capture for capture in CAPTURES}


def selected_captures(names: list[str] | None) -> list[Capture]:
    if not names:
        return list(CAPTURES)
    available = capture_map()
    return [available[name] for name in names]


def run_capture(
    capture: Capture,
    binary: Path,
    output: Path,
    workspace: str | None,
    timeout: float,
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    image_path = output / f"{capture.name}.png"
    report_path = output / f"{capture.name}.json"
    log_path = output / f"{capture.name}.log"
    gate_path = output / f"{capture.name}.capture-ready"
    for path in (image_path, report_path, log_path, gate_path):
        path.unlink(missing_ok=True)

    command = [
        str(binary),
        "--studio",
        "--no-startup-banner",
        "--no-crowd",
        f"--diagnostics-window={capture.width}x{capture.height}",
        f"--diagnostics-capture={image_path}",
        f"--diagnostics-report={report_path}",
        f"--diagnostics-capture-scenario={capture.name}",
        f"--diagnostics-capture-gate={gate_path}",
        f"--diagnostics-capture-settle={capture.settle_frames}",
        "--diagnostics-exit-after-capture",
        "--diagnostics-hide-hud",
        *capture.extra_args,
    ]
    if capture.deck is not None:
        command.append(str((ROOT / capture.deck).resolve()))

    with log_path.open("w", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.monotonic() + timeout
        if workspace is not None:
            placed = place_and_verify_window(
                process.pid,
                workspace,
                min(deadline, time.monotonic() + 15.0),
            )
            if placed is None:
                observed = ", ".join(
                    f"{window.window_id}@{window.workspace}/{window.layout}"
                    for window in aerospace_windows_for_pid(process.pid)
                ) or "none"
                terminate_process(process)
                raise RuntimeError(
                    f"{capture.name}: window placement failed; observed {observed}"
                )
            print(
                f"[{capture.name}] verified window {placed.window_id} on workspace "
                f"{placed.workspace} ({placed.layout})",
                flush=True,
            )
        gate_path.touch()
        try:
            return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            terminate_process(process)
            raise RuntimeError(f"{capture.name}: capture timed out; see {log_path}")
    if return_code != 0:
        tail = "\n".join(log_path.read_text(errors="replace").splitlines()[-30:])
        raise RuntimeError(f"{capture.name}: app exited {return_code}\n{tail}")
    if not image_path.is_file() or not report_path.is_file():
        raise RuntimeError(f"{capture.name}: image/report missing; see {log_path}")
    assert_frame_not_blank(image_path, capture.name)
    with Image.open(image_path) as image:
        if image.size != (capture.width, capture.height):
            raise RuntimeError(
                f"{capture.name}: expected {capture.width}x{capture.height}, got "
                f"{image.width}x{image.height}"
            )
    print(f"[{capture.name}] captured {capture.width}x{capture.height}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--binary",
        type=Path,
        default=ROOT / "zig-out" / "Rayslides.app" / "Contents" / "MacOS" / "rayslides",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workspace")
    parser.add_argument("--scenario", action="append", choices=sorted(capture_map()))
    parser.add_argument("--timeout", type=float, default=45.0)
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise SystemExit(f"Rayslides binary not found: {binary}")
    output = args.output.resolve()
    for index, capture in enumerate(selected_captures(args.scenario)):
        # Back-to-back launches race the window manager: the next window can be
        # captured before the compositor has it, which returns a dead frame.
        # Give it a beat, and retry the frames that still come back empty.
        if index:
            time.sleep(INTER_CAPTURE_PAUSE)
        for attempt in range(1, CAPTURE_ATTEMPTS + 1):
            try:
                run_capture(capture, binary, output, args.workspace, args.timeout)
                break
            except RuntimeError as error:
                if "never rendered" not in str(error) or attempt == CAPTURE_ATTEMPTS:
                    raise
                print(
                    f"[{capture.name}] frame never rendered; retrying "
                    f"({attempt}/{CAPTURE_ATTEMPTS - 1})",
                    flush=True,
                )
                time.sleep(RETRY_PAUSE)


if __name__ == "__main__":
    main()
