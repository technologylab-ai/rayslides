#!/usr/bin/env python3
"""Capture true 2560x1440 presentation framebuffers for documentation.

Each capture runs the real presentation renderer, pairs with the local
Presenter Companion without exposing its private capability, navigates to a
deterministic slide/state, and opens the framebuffer gate only after the target
is stable. The app itself writes the PNG at the requested logical resolution.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from studio_baseline import ROOT, aerospace_windows_for_pid, place_and_verify_window, terminate_process


@dataclass(frozen=True)
class Capture:
    name: str
    slide_index: int
    rewind_steps: int = 0
    wait_for_states: float = 0.0


CAPTURES: tuple[Capture, ...] = (
    Capture("showcase-authoring", 0, rewind_steps=2),
    Capture("showcase-typography", 1),
    Capture("showcase-geometry", 2),
    Capture("showcase-media", 3),
    Capture("showcase-motion", 5, wait_for_states=2.5),
)


def capture_map() -> dict[str, Capture]:
    return {capture.name: capture for capture in CAPTURES}


def presenter_request(url: str, token: str, path: str, body: dict | None = None) -> dict:
    separator = "&" if "?" in path else "?"
    request = urllib.request.Request(
        f"{url}{path}{separator}token={urllib.parse.quote(token)}",
        data=None if body is None else json.dumps(body).encode(),
        headers={} if body is None else {"Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def decode_pairing_url(window_id: str, qr_path: Path, deadline: float) -> str:
    while time.monotonic() < deadline:
        subprocess.run(
            ["screencapture", "-x", "-l", window_id, str(qr_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        decoded = subprocess.run(
            ["zbarimg", "-q", "--raw", str(qr_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        pairing_url = decoded.stdout.strip()
        if pairing_url.startswith("http"):
            return pairing_url
        time.sleep(0.1)
    raise RuntimeError("Presenter pairing QR was not ready before the deadline")


def wait_for_slide(origin: str, token: str, target: int, deadline: float) -> dict:
    last_state: dict = {}
    while time.monotonic() < deadline:
        last_state = presenter_request(origin, token, "/api/v1/presenter/state")
        if last_state.get("current_slide") == target:
            return last_state
        time.sleep(0.05)
    raise RuntimeError(
        f"Presenter did not reach slide {target + 1}; last state was "
        f"{last_state.get('current_slide')}"
    )


def send_command(origin: str, token: str, command: str, sequence: int) -> None:
    response = presenter_request(
        origin,
        token,
        "/api/v1/presenter/command",
        {"command": command, "seq": sequence},
    )
    if not response.get("queued"):
        raise RuntimeError(f"Presenter rejected {command} sequence {sequence}")


def keep_connected(origin: str, token: str, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        presenter_request(origin, token, "/api/v1/presenter/state")
        time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))


def run_capture(
    capture: Capture,
    binary: Path,
    deck: Path,
    output: Path,
    workspace: str,
    width: int,
    height: int,
    timeout: float,
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    image_path = output / f"{capture.name}.png"
    report_path = output / f"{capture.name}.json"
    log_path = output / f"{capture.name}.log"
    gate_path = output / f"{capture.name}.capture-ready"
    qr_path = output / f"{capture.name}.pairing.png"
    for path in (image_path, report_path, log_path, gate_path, qr_path):
        path.unlink(missing_ok=True)

    command = [
        str(binary),
        "--no-crowd",
        "--diagnostics-presenter-session",
        "--diagnostics-presentation-capture",
        f"--diagnostics-window={width}x{height}",
        f"--diagnostics-capture={image_path}",
        f"--diagnostics-report={report_path}",
        f"--diagnostics-capture-scenario={capture.name}",
        f"--diagnostics-capture-gate={gate_path}",
        "--diagnostics-capture-settle=30",
        "--diagnostics-exit-after-capture",
        "--diagnostics-hide-hud",
        str(deck),
    ]
    deadline = time.monotonic() + timeout
    with log_path.open("w", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
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
                raise RuntimeError(f"window placement failed; observed {observed}")
            print(
                f"[{capture.name}] verified window {placed.window_id} on workspace "
                f"{placed.workspace} ({placed.layout})",
                flush=True,
            )

            pairing = decode_pairing_url(placed.window_id, qr_path, deadline)
            parsed = urllib.parse.urlsplit(pairing)
            token = parsed.fragment
            if len(token) != 64:
                raise RuntimeError("Presenter pairing capability had an unexpected format")
            origin = f"{parsed.scheme}://{parsed.netloc}"

            # Pairing hides the setup overlay. Let the first slide's authored
            # timed states settle so navigation begins from a known endpoint.
            wait_for_slide(origin, token, 0, deadline)
            keep_connected(origin, token, 2.5)
            sequence = 0
            if capture.rewind_steps:
                for _ in range(capture.rewind_steps):
                    sequence += 1
                    send_command(origin, token, "previous", sequence)
                    keep_connected(origin, token, 1.0)
            else:
                for slide_index in range(1, capture.slide_index + 1):
                    sequence += 1
                    send_command(origin, token, "next", sequence)
                    wait_for_slide(origin, token, slide_index, deadline)
                    keep_connected(origin, token, 0.8)
            if capture.wait_for_states:
                keep_connected(origin, token, capture.wait_for_states)

            gate_path.touch()
            return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            if return_code != 0:
                tail = "\n".join(log_path.read_text(errors="replace").splitlines()[-30:])
                raise RuntimeError(f"app exited {return_code}\n{tail}")
        except Exception:
            terminate_process(process)
            raise
        finally:
            qr_path.unlink(missing_ok=True)

    if not image_path.is_file() or not report_path.is_file():
        raise RuntimeError(f"image/report missing; see {log_path}")
    with Image.open(image_path) as image:
        if image.size != (width, height):
            raise RuntimeError(
                f"expected a native {width}x{height} framebuffer, got "
                f"{image.width}x{image.height}"
            )
    report = json.loads(report_path.read_text())
    if report.get("capture") != {"width": width, "height": height}:
        raise RuntimeError(f"capture report did not prove {width}x{height}")
    print(f"[{capture.name}] captured native {width}x{height}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--binary",
        type=Path,
        default=ROOT / "zig-out" / "Rayslides.app" / "Contents" / "MacOS" / "rayslides",
    )
    parser.add_argument(
        "--deck",
        type=Path,
        default=ROOT / "testslides" / "studio-showcase.sld",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workspace", default="12")
    parser.add_argument("--width", type=int, default=2560)
    parser.add_argument("--height", type=int, default=1440)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--scenario", action="append", choices=sorted(capture_map()))
    args = parser.parse_args()

    if args.width < 1920 or args.height < 1080:
        raise SystemExit("documentation presentation captures must be at least 1920x1080")
    names = args.scenario or [capture.name for capture in CAPTURES]
    for name in names:
        run_capture(
            capture_map()[name],
            args.binary.resolve(),
            args.deck.resolve(),
            args.output.resolve(),
            args.workspace,
            args.width,
            args.height,
            args.timeout,
        )


if __name__ == "__main__":
    main()
