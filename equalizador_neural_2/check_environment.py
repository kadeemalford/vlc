"""Offline readiness check. Does not import instrument drivers or open connections."""
from importlib import import_module
from importlib.metadata import version
from pathlib import Path
import platform
import sys


def check():
    root = Path(__file__).resolve().parents[1]
    print(f'Python: {platform.python_version()} ({sys.executable})')
    failed = []
    for name in ('numpy', 'scipy', 'torch', 'matplotlib'):
        try:
            import_module(name)
            print(f'{name}: {version(name)}')
        except (ImportError, OSError) as exc:
            failed.append(name)
            print(f'{name}: unavailable ({exc})')
    for relative in ('equalizador_neural/capture_sync.py', 'equalizador_neural/benchmark_detectors.py',
                     'equalizador_neural/matlab/collect_capture.m',
                     'vlc-system-matlab-alarm-care-pro-scripts/src/main'):
        exists = (root/relative).exists()
        print(f'{relative}: {"OK" if exists else "MISSING"}')
        if not exists:
            failed.append(relative)
    print('No instruments contacted. MATLAB/VISA/setup readiness must be checked locally.')
    return int(bool(failed))


if __name__ == '__main__':
    raise SystemExit(check())
