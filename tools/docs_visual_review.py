#!/usr/bin/env python3
"""Render every documentation page for the manual review gate."""

from __future__ import annotations

import argparse
import base64
import json
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

import websocket


PAGES = (
    "index.html",
    "getting-started.html",
    "studio.html",
    "motion.html",
    "presenter.html",
    "crowdplay.html",
    "format.html",
    "reference.html",
)

VIEWPORTS = {
    "desktop": (1440, 900),
    "mobile": (430, 932),
}


def chrome_path() -> str:
    mac_path = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if mac_path.exists():
        return str(mac_path)
    for name in ("google-chrome", "chromium", "chromium-browser"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("Chrome or Chromium is required")


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for_json(url: str, timeout: float = 10) -> object:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                return json.load(response)
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"Chrome did not expose {url}")


class DevTools:
    def __init__(self, url: str) -> None:
        self.socket = websocket.create_connection(url, timeout=60)
        self.serial = 0

    def close(self) -> None:
        self.socket.close()

    def command(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]:
        self.serial += 1
        serial = self.serial
        self.socket.send(json.dumps({"id": serial, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.socket.recv())
            if message.get("id") != serial:
                continue
            if "error" in message:
                raise RuntimeError(message["error"])
            return message.get("result", {})


def render(base_url: str, output: Path) -> None:
    port = free_port()
    profile = Path(tempfile.mkdtemp(prefix="rayslides-doc-review-profile-"))
    process = subprocess.Popen(
        [
            chrome_path(),
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--remote-allow-origins=*",
            f"--remote-debugging-port={port}",
            f"--user-data-dir={profile}",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    client = None
    try:
        targets = wait_for_json(f"http://127.0.0.1:{port}/json/list")
        page = next(target for target in targets if target.get("type") == "page")
        client = DevTools(page["webSocketDebuggerUrl"])
        client.command("Page.enable")
        for viewport_name, (width, height) in VIEWPORTS.items():
            client.command(
                "Emulation.setDeviceMetricsOverride",
                {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False},
            )
            for page_name in PAGES:
                client.command("Page.navigate", {"url": f"{base_url.rstrip('/')}/{page_name}"})
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    ready = client.command(
                        "Runtime.evaluate",
                        {"expression": "document.readyState", "returnByValue": True},
                    )
                    if ready["result"]["value"] == "complete":
                        break
                    time.sleep(0.1)
                client.command(
                    "Runtime.evaluate",
                    {
                        "expression": "document.querySelectorAll('img').forEach(image => image.loading = 'eager'); window.scrollTo(0, document.documentElement.scrollHeight);",
                        "returnByValue": True,
                    },
                )
                client.command(
                    "Runtime.evaluate",
                    {
                        "expression": "Promise.race([Promise.all(Array.from(document.images, image => image.complete ? true : new Promise(resolve => { image.addEventListener('load', resolve, {once:true}); image.addEventListener('error', resolve, {once:true}); }))), new Promise(resolve => setTimeout(resolve, 5000))]).then(() => window.scrollTo(0, 0))",
                        "awaitPromise": True,
                        "returnByValue": True,
                    },
                )
                metrics = client.command("Page.getLayoutMetrics")
                size = metrics["cssContentSize"]
                capture = client.command(
                    "Page.captureScreenshot",
                    {
                        "format": "png",
                        "fromSurface": True,
                        "captureBeyondViewport": True,
                        "clip": {"x": 0, "y": 0, "width": size["width"], "height": size["height"], "scale": 1},
                    },
                )
                target = output / viewport_name / f"{Path(page_name).stem}.png"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(base64.b64decode(capture["data"]))
                print(f"{viewport_name:7} {page_name:22} {int(size['width'])}x{int(size['height'])}")
    finally:
        if client is not None:
            client.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8768")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    render(args.base_url, args.output)


if __name__ == "__main__":
    main()
