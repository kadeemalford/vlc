"""Explicit reuse of proposal 2; keep the complete repository together."""
from pathlib import Path
import sys

SOURCE = Path(__file__).resolve().parents[1] / 'equalizador_neural'
if not (SOURCE / 'capture_sync.py').is_file():
    raise RuntimeError('Proposal 2 sources are required next to equalizador_neural_2')
sys.path.insert(0, str(SOURCE))
