"""Keep the baseline harness dependencies in a runner-local virtualenv."""
import os
import subprocess
import venv
from pathlib import Path

root = Path(os.environ['RUNNER_TEMP']) / 'rayslides-python'
venv.EnvBuilder(with_pip=True).create(root)
binary_dir = root / ('Scripts' if os.name == 'nt' else 'bin')
python = binary_dir / ('python.exe' if os.name == 'nt' else 'python')
subprocess.run([str(python), '-m', 'pip', 'install', 'Pillow==12.3.0'], check=True)
with open(os.environ['GITHUB_PATH'], 'a', encoding='utf-8') as output:
    output.write(str(binary_dir) + '\n')
