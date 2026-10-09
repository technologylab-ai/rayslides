"""Install the exact, checksum-verified release used by this repository's CI."""

import hashlib
import json
import os
import platform
import subprocess
import tarfile
import urllib.request
import zipfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    version = (root / '.zig-version').read_text().strip()
    metadata = json.loads((root / '.github/zig-release.json').read_text())
    if version != '0.17.0' or metadata['version'] != version:
        raise RuntimeError('Expected exact Zig 0.17.0')
    architecture = {'x86_64': 'x86_64', 'AMD64': 'x86_64',
                    'arm64': 'aarch64', 'aarch64': 'aarch64'}[platform.machine()]
    system = {'Linux': 'linux', 'Darwin': 'macos', 'Windows': 'windows'}[platform.system()]
    artifact = metadata['artifacts'][f'{architecture}-{system}']
    if not artifact['tarball'].startswith('https://ziglang.org/download/0.17.0/'):
        raise RuntimeError('Expected an official release archive')
    directory = Path(os.environ['RUNNER_TEMP']) / 'rayslides-zig'
    directory.mkdir()
    archive = directory / ('zig.zip' if system == 'windows' else 'zig.tar.xz')
    with urllib.request.urlopen(artifact['tarball'], timeout=180) as response:
        archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != artifact['shasum']:
        raise RuntimeError('Zig archive checksum mismatch')
    if system == 'windows':
        with zipfile.ZipFile(archive) as package:
            package.extractall(directory)
        compiler, = directory.glob('*/zig.exe')
    else:
        with tarfile.open(archive) as package:
            package.extractall(directory, filter='data')
        compiler, = directory.glob('*/zig')
    actual = subprocess.check_output([str(compiler), 'version'], text=True).strip()
    if actual != version:
        raise RuntimeError(f'Expected {version}, downloaded {actual}')
    with open(os.environ['GITHUB_PATH'], 'a', encoding='utf-8') as output:
        output.write(str(compiler.parent) + '\n')
    print(f'Installed Zig {actual} for {architecture}-{system}')


if __name__ == '__main__':
    main()
