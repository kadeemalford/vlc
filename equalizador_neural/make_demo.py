"""Dados artificiais para smoke test; NAO modelam a bancada fisica."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.io import savemat
from scipy.signal import lfilter


def generate(out, seed=123, frames=8, bits=128):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(seed)
    sps = 10
    for split in ('train', 'val', 'test'):
        for i in range(frames):
            y = rng.integers(0, 2, bits)
            signed = 2*y-1
            ideal = np.repeat(np.column_stack([signed, -signed]).reshape(-1), sps//2)
            raw = lfilter([0.25], [1, -0.75], ideal.astype(float))
            raw = np.tanh(1.5*raw) + rng.normal(0, 0.2 if i % 2 == 0 else 0.6, len(raw))
            aligned = raw/max(np.max(np.abs(raw)), 1e-8)
            status = 'error' if i == frames-1 else 'ok'
            meta = dict(capture_id=f'demo_{split}_{i:04d}', session_id=f'demo_{split}',
                        condition_id='low_noise' if i % 2 == 0 else 'high_noise',
                        split=split, synthetic=True, payload_type='random', payload_seed=seed)
            savemat(out/f'{meta["capture_id"]}.mat', dict(metadata_json=json.dumps(meta),
                    tx_bits=y, tx_samples=ideal, rx_raw=raw,
                    rx_aligned=aligned if status == 'ok' else np.array([]),
                    sps=sps, bit_rate=1e6, rx_sample_rate=1e7, tx_sample_rate=1e7,
                    status=status, sync_mode='assisted_full_tx',
                    stage='synchronization', error_message='synthetic failure' if status == 'error' else '',
                    total_seconds=0.1))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--seed', type=int, default=123)
    parser.add_argument('--frames', type=int, default=8)
    parser.add_argument('--bits', type=int, default=128)
    args = parser.parse_args()
    if args.frames < 2 or args.bits < 1:
        parser.error('frames >= 2 e bits >= 1')
    generate(args.out, args.seed, args.frames, args.bits)
