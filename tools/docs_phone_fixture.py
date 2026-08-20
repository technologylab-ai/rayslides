#!/usr/bin/env python3
"""Serve the shipped phone interface with stable documentation data."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
PRESENTER_HTML = ROOT / "src" / "assets" / "presenter.html"
CROWDPLAY_HTML = ROOT / "src" / "assets" / "crowdplay.html"
PREVIEW_IMAGE = ROOT / "docs" / "images" / "morph-final.png"


def presenter_state() -> dict[str, object]:
    return {
        "revision": 7,
        "current_slide": 3,
        "slide_count": 12,
        "notes": "Explain why the three cards keep their IDs. Pause before the final connection appears.",
        "next_notes": "Ask the room which step deserves more detail.",
        "can_previous": True,
        "can_next": True,
        "pointer_enabled": True,
        "drawing_enabled": True,
        "preview_ready": True,
        "preview_revision": 4,
        "server_now_ms": 1_780_000_000_000,
        "elapsed_ms": 754_000,
    }


def crowdplay_state(mode: str) -> dict[str, object]:
    revealed = mode == "results"
    choices = [
        {"id": "source", "label": "The working source", "votes": 5},
        {"id": "design", "label": "The finished design", "votes": 8},
        {"id": "demo", "label": "A live demo", "votes": 4},
        {"id": "all", "label": "All three", "votes": 13},
    ]
    return {
        "session_id": "docs-session",
        "revision": 12,
        "connected": 37,
        "joined": True,
        "server_name": "Rayslides room",
        "poll": {
            "id": "next-slide",
            "prompt": "What should the next slide show?",
            "open": not revealed,
            "revealed": revealed,
            "selected": "all",
            "vote_seq": 2,
            "total": 30,
            "choices": choices,
        },
    }


class FixtureHandler(BaseHTTPRequestHandler):
    interface = "presenter"
    mode = "notes"

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, value: object) -> None:
        self.send_bytes(json.dumps(value).encode(), "application/json; charset=utf-8")

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if self.interface == "presenter":
            self.presenter_get(path)
        else:
            self.crowdplay_get(path)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        if self.interface == "presenter":
            self.send_json({"ok": True})
        else:
            self.send_json(crowdplay_state(self.mode))

    def presenter_get(self, path: str) -> None:
        if path in {"/", "/presenter.html"}:
            html = PRESENTER_HTML.read_text()
            seed = (
                '<script>sessionStorage.setItem('
                '"rayslides:presenter-token:" + location.host + ":mode", '
                f'"{self.mode}");</script>\n  '
            )
            html = html.replace("<script>\n    (() => {", seed + "<script>\n    (() => {", 1)
            if self.mode == "pointer":
                demo = """<script>
setTimeout(() => {
  const dot = document.getElementById("pointerDot");
  dot.style.left = "68%";
  dot.style.top = "43%";
  dot.hidden = false;
}, 900);
</script>
"""
                html = html.replace("</body>", demo + "</body>")
            elif self.mode == "draw":
                demo = """<script>
setTimeout(() => {
  const canvas = document.getElementById("drawingCanvas");
  const context = canvas.getContext("2d");
  context.lineCap = "round";
  context.lineJoin = "round";
  context.strokeStyle = "#f3314d";
  context.lineWidth = 5;
  context.beginPath();
  context.moveTo(canvas.clientWidth * .22, canvas.clientHeight * .63);
  context.quadraticCurveTo(canvas.clientWidth * .44, canvas.clientHeight * .28, canvas.clientWidth * .72, canvas.clientHeight * .48);
  context.stroke();
}, 900);
</script>
"""
                html = html.replace("</body>", demo + "</body>")
            self.send_bytes(html.encode(), "text/html; charset=utf-8")
            return
        if path == "/api/v1/presenter/state":
            self.send_json(presenter_state())
            return
        if path == "/api/v1/presenter/preview":
            self.send_bytes(PREVIEW_IMAGE.read_bytes(), "image/png")
            return
        self.send_json({"error": "Not found"})

    def crowdplay_get(self, path: str) -> None:
        if path in {"/", "/crowdplay.html"}:
            html = CROWDPLAY_HTML.read_text()
            saved = {
                "id": "docsclient01",
                "name": "Ada",
                "joined": True,
                "session": "docs-session",
                "revision": 0,
                "pollId": "",
                "seq": 0,
            }
            seed = (
                '<script>localStorage.setItem('
                '"rayslides:crowdplay:" + location.host, '
                f'JSON.stringify({json.dumps(saved)}));</script>\n  '
            )
            html = html.replace("<script>\n    (() => {", seed + "<script>\n    (() => {", 1)
            self.send_bytes(html.encode(), "text/html; charset=utf-8")
            return
        if path == "/api/v1/state":
            self.send_json(crowdplay_state(self.mode))
            return
        self.send_json({"error": "Not found"})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", choices=("presenter", "crowdplay"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--port", type=int, default=8770)
    args = parser.parse_args()
    FixtureHandler.interface = args.interface
    FixtureHandler.mode = args.mode
    try:
        ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler).serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
