#!/usr/bin/env python3
"""Qualify CLI exit and real framebuffer rendering without timing comparisons."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path

from PIL import Image
from studio_baseline import assert_frame_not_blank

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cli-only', action='store_true')
    parser.add_argument('--no-display', action='store_true', help='Require an ordinary startup error without a Linux display')
    parser.add_argument('--neovim', action='store_true')
    parser.add_argument('--visible', action='store_true', help='Map the capture window (needed by some macOS compositors)')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(binary), '--version'], text=True, timeout=30).strip()
    expected_version = re.search(r'^\s*\.version\s*=\s*"([^"]+)"', (ROOT / 'build.zig.zon').read_text(), re.MULTILINE).group(1)
    if version != f'rayslides {expected_version}':
        raise RuntimeError(f'Unexpected version output: {version!r}')
    help_text = subprocess.check_output([str(binary), '--help'], text=True, timeout=30)
    if '--studio' not in help_text or '--portable-show=' not in help_text:
        raise RuntimeError('CLI help lost its Studio or portable-show command')
    print(f'CLI version/help passed: {version}', flush=True)
    if args.cli_only:
        return
    if args.no_display:
        environment = dict(os.environ)
        environment.pop('DISPLAY', None)
        environment.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run(
            [str(binary), '--studio', '--no-crowd', '--diagnostics-hidden',
             f'--diagnostics-capture={output / "unexpected.png"}', '--diagnostics-exit-after-capture'],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=30)
        (output / 'no-display.log').write_text(result.stdout + result.stderr)
        if result.returncode != 1 or 'WindowInitializationFailed' not in result.stderr:
            raise RuntimeError(f'Expected ordinary no-display startup error, got {result.returncode}')
        print('No-display startup exits with an ordinary error', flush=True)
        return
    for name in (['studio', 'neovim'] if args.neovim else ['studio']):
        image = output / f'{name}.png'
        report = output / f'{name}.json'
        command = [str(binary), '--studio', '--no-crowd',
                   '--diagnostics-window=900x506', '--diagnostics-large-deck=4',
                   f'--diagnostics-capture={image}', f'--diagnostics-report={report}',
                   f'--diagnostics-capture-scenario=zig-port-{name}',
                   '--diagnostics-exit-after-capture', '--diagnostics-hide-hud']
        if not args.visible:
            command += ['--diagnostics-hidden']
        if name == 'neovim':
            command += ['--diagnostics-neovim-editor', '--neovim-clean']
        with (output / f'{name}.log').open('w') as log:
            process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                return_code = process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
                raise RuntimeError(f'{name} render did not exit after capture')
        if return_code:
            raise RuntimeError(f'{name} exited {return_code}; see {output / f"{name}.log"}')
        result = json.loads(report.read_text())
        if result['capture'] != {'width': 900, 'height': 506}:
            raise RuntimeError(f'Unexpected capture size: {result["capture"]}')
        if result['deck']['slides'] != 4 or result['deck']['active_items'] < 1:
            raise RuntimeError(f'Unexpected deck state: {result["deck"]}')
        if result['render']['full_count'] < 1 or result['render']['total_slides'] != 4:
            raise RuntimeError(f'Expected an actual full render: {result["render"]}')
        with Image.open(image) as capture:
            if capture.size != (900, 506):
                raise RuntimeError(f'Unexpected PNG dimensions: {capture.size}')
        assert_frame_not_blank(image, name)
        print(f'{name} framebuffer render/exit passed: 900x506, four parsed/rendered slides', flush=True)


if __name__ == '__main__':
    main()
