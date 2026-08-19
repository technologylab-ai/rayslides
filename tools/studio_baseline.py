#!/usr/bin/env python3
"""Capture and compare deterministic Rayslides Studio visual/perf baselines.

The app owns framebuffer capture and JSON reporting. This harness only starts
the requested diagnostic scenarios, optionally moves their windows to an
Aerospace workspace, and compares results with the checked-in baselines.
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageStat
except ImportError as exc:  # pragma: no cover - environment guidance
    raise SystemExit("Studio baselines require Python Pillow (pip install Pillow)") from exc


ROOT = Path(__file__).resolve().parents[1]
BASELINE_DIR = ROOT / "tests" / "studio_baselines"
DEFAULT_ARTIFACT_DIR = ROOT / "zig-out" / "studio-baselines"


@dataclass(frozen=True)
class Scenario:
    name: str
    width: int
    height: int
    slides: int
    extra_args: tuple[str, ...] = ()
    expected_mode: str = "full"
    expected_rebuilt: int | None = None

    @property
    def rebuilt(self) -> int:
        return self.slides if self.expected_rebuilt is None else self.expected_rebuilt


SCENARIOS: tuple[Scenario, ...] = (
    Scenario(
        "compact-properties",
        900,
        506,
        24,
        ("--diagnostics-select=title_0",),
    ),
    Scenario(
        "default-command-palette",
        1600,
        900,
        24,
        ("--diagnostics-command-palette",),
    ),
    Scenario(
        "large-precision",
        2560,
        1440,
        24,
        ("--diagnostics-select=title_0", "--diagnostics-precision-view"),
    ),
    Scenario(
        "incremental-160",
        1600,
        900,
        160,
        ("--diagnostics-incremental-edit=1",),
        expected_mode="partial",
        expected_rebuilt=1,
    ),
)


@dataclass(frozen=True)
class ImageComparison:
    mean_absolute: float
    rms: float
    changed_ratio: float
    maximum: int

    def acceptable(self) -> bool:
        # This intentionally tolerates small GPU/font rasterization differences
        # while still rejecting moved chrome, clipped text, missing panels, or
        # changed colors over a meaningful area.
        return self.mean_absolute <= 2.5 and self.rms <= 10.0 and self.changed_ratio <= 0.03


@dataclass(frozen=True)
class AerospaceWindow:
    window_id: str
    workspace: str
    app_name: str
    layout: str


def scenario_map() -> dict[str, Scenario]:
    return {scenario.name: scenario for scenario in SCENARIOS}


def selected_scenarios(names: list[str] | None) -> list[Scenario]:
    if not names:
        return list(SCENARIOS)
    available = scenario_map()
    return [available[name] for name in names]


def compare_images(expected_path: Path, actual_path: Path, diff_path: Path | None = None) -> ImageComparison:
    with Image.open(expected_path) as expected_image, Image.open(actual_path) as actual_image:
        expected = expected_image.convert("RGB")
        actual = actual_image.convert("RGB")
        if expected.size != actual.size:
            raise AssertionError(f"image size changed: expected {expected.size}, got {actual.size}")
        difference = ImageChops.difference(expected, actual)
        stats = ImageStat.Stat(difference)
        mean_absolute = sum(stats.mean) / len(stats.mean)
        rms = math.sqrt(sum(value * value for value in stats.rms) / len(stats.rms))
        extrema = difference.getextrema()
        maximum = max(channel[1] for channel in extrema)

        masks = [channel.point(lambda value: 255 if value > 12 else 0) for channel in difference.split()]
        changed = ImageChops.lighter(ImageChops.lighter(masks[0], masks[1]), masks[2])
        changed_ratio = changed.histogram()[255] / (expected.width * expected.height)

        result = ImageComparison(mean_absolute, rms, changed_ratio, maximum)
        if diff_path is not None and not result.acceptable():
            diff_path.parent.mkdir(parents=True, exist_ok=True)
            difference.point(lambda value: min(255, value * 4)).save(diff_path)
        return result


def metric_limit(baseline: float, ratio: float, allowance: float) -> float:
    return max(baseline * ratio, baseline + allowance)


def validate_capture_image(scenario: Scenario, image_path: Path) -> list[str]:
    with Image.open(image_path) as image:
        if image.size != (scenario.width, scenario.height):
            return [f"capture image size changed: {image.width}x{image.height}"]
    return []


def validate_report(scenario: Scenario, report: dict, baseline: dict | None) -> list[str]:
    errors: list[str] = []
    capture = report.get("capture", {})
    deck = report.get("deck", {})
    render = report.get("render", {})
    if report.get("schema") != 1:
        errors.append(f"unsupported report schema {report.get('schema')!r}")
    if report.get("scenario") != scenario.name:
        errors.append(f"scenario mismatch: {report.get('scenario')!r}")
    if (capture.get("width"), capture.get("height")) != (scenario.width, scenario.height):
        errors.append(f"capture size changed: {capture.get('width')}x{capture.get('height')}")
    if deck.get("slides") != scenario.slides:
        errors.append(f"deck slide count changed: {deck.get('slides')}")
    if render.get("last_mode") != scenario.expected_mode:
        errors.append(f"expected {scenario.expected_mode} rebuild, got {render.get('last_mode')}")
    if render.get("last_rebuilt") != scenario.rebuilt:
        errors.append(f"expected {scenario.rebuilt} rebuilt slides, got {render.get('last_rebuilt')}")
    if render.get("total_slides") != scenario.slides:
        errors.append(f"render total changed: {render.get('total_slides')}")
    if scenario.expected_mode == "partial":
        if render.get("full_count") != 1 or render.get("partial_count") != 1:
            errors.append("incremental scenario must contain one full and one partial rebuild")
    elif render.get("full_count") != 1:
        errors.append("visual scenario must contain exactly one full rebuild")

    if baseline is not None:
        baseline_render = baseline["render"]
        full_ms = float(render.get("last_full_ms", 0))
        baseline_full_ms = float(baseline_render.get("last_full_ms", 0))
        full_limit = metric_limit(baseline_full_ms, 2.0, 5.0)
        if full_ms > full_limit:
            errors.append(f"full rebuild regressed: {full_ms:.3f} ms > {full_limit:.3f} ms")
        if scenario.expected_mode == "partial":
            partial_ms = float(render.get("last_partial_ms", 0))
            baseline_partial_ms = float(baseline_render.get("last_partial_ms", 0))
            partial_limit = metric_limit(baseline_partial_ms, 2.5, 2.0)
            if partial_ms > partial_limit:
                errors.append(f"partial rebuild regressed: {partial_ms:.3f} ms > {partial_limit:.3f} ms")
    return errors


def aerospace_windows_for_pid(pid: int) -> list[AerospaceWindow]:
    aerospace = shutil.which("aerospace")
    if aerospace is None:
        return []
    completed = subprocess.run(
        [
            aerospace,
            "list-windows",
            "--monitor",
            "all",
            "--pid",
            str(pid),
            "--format",
            "%{window-id}|%{workspace}|%{app-name}|%{window-layout}",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        return []
    windows: list[AerospaceWindow] = []
    for line in completed.stdout.splitlines():
        parts = line.split("|", 3)
        if len(parts) == 4:
            windows.append(AerospaceWindow(*parts))
    return windows


def place_and_verify_window(pid: int, workspace: str, deadline: float) -> AerospaceWindow | None:
    aerospace = shutil.which("aerospace")
    if aerospace is None:
        return None
    target_window_id: str | None = None
    while time.monotonic() < deadline:
        windows = [window for window in aerospace_windows_for_pid(pid) if window.app_name.casefold() == "rayslides"]
        if target_window_id is None and len(windows) == 1:
            target_window_id = windows[0].window_id
        if target_window_id is not None:
            matching = [window for window in windows if window.window_id == target_window_id]
            if matching and matching[0].workspace == workspace and matching[0].layout == "floating":
                return matching[0]
            moved = subprocess.run(
                [aerospace, "move-node-to-workspace", "--window-id", target_window_id, workspace],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if moved.returncode != 0:
                return None
            floated = subprocess.run(
                [aerospace, "layout", "--window-id", target_window_id, "floating"],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if floated.returncode != 0:
                return None
        time.sleep(0.05)
    return None


def terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def capture_scenario(
    scenario: Scenario,
    binary: Path,
    artifact_dir: Path,
    settle_frames: int,
    timeout: float,
    workspace: str | None,
) -> tuple[Path, Path]:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    image_path = artifact_dir / f"{scenario.name}.png"
    report_path = artifact_dir / f"{scenario.name}.json"
    log_path = artifact_dir / f"{scenario.name}.log"
    gate_path = artifact_dir / f"{scenario.name}.capture-ready"
    diff_path = artifact_dir / f"{scenario.name}.diff.png"
    for path in (image_path, report_path, log_path, gate_path, diff_path):
        path.unlink(missing_ok=True)

    command = [
        str(binary),
        "--studio",
        "--no-startup-banner",
        f"--diagnostics-large-deck={scenario.slides}",
        f"--diagnostics-window={scenario.width}x{scenario.height}",
        f"--diagnostics-capture={image_path}",
        f"--diagnostics-report={report_path}",
        f"--diagnostics-capture-scenario={scenario.name}",
        f"--diagnostics-capture-gate={gate_path}",
        f"--diagnostics-capture-settle={settle_frames}",
        "--diagnostics-exit-after-capture",
        "--diagnostics-hide-hud",
        *scenario.extra_args,
    ]
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
        if workspace and platform.system() == "Darwin":
            placed = place_and_verify_window(process.pid, workspace, min(deadline, time.monotonic() + 8.0))
            if placed is None:
                terminate_process(process)
                raise RuntimeError(
                    f"{scenario.name}: could not verify the launched Rayslides window on "
                    f"Aerospace workspace {workspace} with floating layout; capture aborted"
                )
            print(
                f"[{scenario.name}] verified window {placed.window_id} on workspace "
                f"{placed.workspace} ({placed.layout})",
                flush=True,
            )
        gate_path.touch()
        try:
            return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            terminate_process(process)
            raise RuntimeError(f"{scenario.name} timed out after {timeout:.0f}s; see {log_path}")
    if return_code != 0:
        tail = "\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-30:])
        raise RuntimeError(f"{scenario.name} exited {return_code}; see {log_path}\n{tail}")
    if not image_path.is_file() or not report_path.is_file():
        raise RuntimeError(f"{scenario.name} did not produce image/report; see {log_path}")
    return image_path, report_path


def run_capture(args: argparse.Namespace, update: bool) -> int:
    binary = Path(args.binary).resolve()
    if not binary.is_file():
        raise SystemExit(f"Rayslides binary not found: {binary}; build it first")
    artifact_dir = Path(args.artifacts).resolve()
    failures: list[str] = []
    for scenario in selected_scenarios(args.scenario):
        print(f"[{scenario.name}] capturing {scenario.width}x{scenario.height} …", flush=True)
        actual_image, actual_report_path = capture_scenario(
            scenario,
            binary,
            artifact_dir,
            args.settle_frames,
            args.timeout,
            args.workspace,
        )
        actual_report = json.loads(actual_report_path.read_text(encoding="utf-8"))
        capture_errors = validate_report(scenario, actual_report, None)
        capture_errors.extend(validate_capture_image(scenario, actual_image))
        if capture_errors:
            failures.extend(f"{scenario.name}: {error}" for error in capture_errors)
            continue
        baseline_image = BASELINE_DIR / actual_image.name
        baseline_report_path = BASELINE_DIR / actual_report_path.name
        if update:
            BASELINE_DIR.mkdir(parents=True, exist_ok=True)
            shutil.copy2(actual_image, baseline_image)
            shutil.copy2(actual_report_path, baseline_report_path)
            print(f"[{scenario.name}] baseline updated")
            continue
        if not baseline_image.is_file() or not baseline_report_path.is_file():
            failures.append(f"{scenario.name}: missing baseline; run the update step")
            continue
        baseline_report = json.loads(baseline_report_path.read_text(encoding="utf-8"))
        report_errors = validate_report(scenario, actual_report, baseline_report)
        try:
            image_result = compare_images(
                baseline_image,
                actual_image,
                artifact_dir / f"{scenario.name}.diff.png",
            )
            if not image_result.acceptable():
                report_errors.append(
                    "visual delta too large: "
                    f"mean={image_result.mean_absolute:.3f}, rms={image_result.rms:.3f}, "
                    f"changed={image_result.changed_ratio:.2%}, max={image_result.maximum}"
                )
        except AssertionError as error:
            report_errors.append(str(error))
        if report_errors:
            failures.extend(f"{scenario.name}: {error}" for error in report_errors)
        else:
            render = actual_report["render"]
            print(
                f"[{scenario.name}] OK — {render['last_mode']} {render['last_rebuilt']}/{render['total_slides']}, "
                f"full {render['last_full_ms']:.3f} ms, partial {render['last_partial_ms']:.3f} ms"
            )
    if failures:
        print("\nStudio baseline failures:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(f"Artifacts: {artifact_dir}", file=sys.stderr)
        return 1
    return 0


def self_test() -> int:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        expected = root / "expected.png"
        same = root / "same.png"
        changed = root / "changed.png"
        wrong_size = root / "wrong-size.png"
        Image.new("RGB", (20, 20), (5, 11, 22)).save(expected)
        Image.new("RGB", (20, 20), (5, 11, 22)).save(same)
        Image.new("RGB", (20, 20), (240, 40, 120)).save(changed)
        Image.new("RGB", (19, 20), (5, 11, 22)).save(wrong_size)
        assert compare_images(expected, same).acceptable()
        assert not compare_images(expected, changed).acceptable()
        scenario = Scenario("unit", 20, 20, 3)
        assert validate_capture_image(scenario, same) == []
        assert "19x20" in validate_capture_image(scenario, wrong_size)[0]
        report = {
            "schema": 1,
            "scenario": "unit",
            "capture": {"width": 20, "height": 20},
            "deck": {"slides": 3},
            "render": {
                "last_mode": "full",
                "last_rebuilt": 3,
                "total_slides": 3,
                "full_count": 1,
                "partial_count": 0,
                "last_full_ms": 1.0,
            },
        }
        assert validate_report(scenario, report, report) == []
        regressed = json.loads(json.dumps(report))
        regressed["render"]["last_full_ms"] = 10.0
        assert any("regressed" in error for error in validate_report(scenario, regressed, report))
    print("Studio baseline harness self-test passed")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("check", "update"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--binary", default=str(ROOT / "zig-out" / "bin" / "rayslides"))
        subparser.add_argument("--artifacts", default=str(DEFAULT_ARTIFACT_DIR))
        subparser.add_argument("--scenario", action="append", choices=sorted(scenario_map()))
        subparser.add_argument("--settle-frames", type=int, default=120)
        subparser.add_argument("--timeout", type=float, default=45.0)
        subparser.add_argument("--workspace", help="Aerospace workspace used while each macOS window is open")
    subparsers.add_parser("self-test")
    args = parser.parse_args(argv)
    if hasattr(args, "settle_frames") and not 1 <= args.settle_frames <= 600:
        parser.error("--settle-frames must be between 1 and 600")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "self-test":
        return self_test()
    return run_capture(args, update=args.command == "update")


if __name__ == "__main__":
    raise SystemExit(main())
