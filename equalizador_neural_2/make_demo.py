"""Synthetic bandwidth-limited fixtures, NOT a calibrated model of the testbed."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.io import savemat
from scipy.signal import butter, sosfilt


def generate(out, frames=3, bits=128, seed=120, rates=(1000000, 2000000)):
    if frames < 1 or bits < 8 or seed < 0 or not rates or any(r <= 0 for r in rates):
        raise ValueError('Invalid demo parameters')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(seed)
    for rate in rates:
        for split in ('train', 'val', 'test'):
            folder = out / split / str(rate)
            folder.mkdir(parents=True)
            for index in range(frames):
                y = rng.integers(0, 2, bits)
                bipolar = 2*y-1
                tx = np.repeat(np.column_stack([bipolar, -bipolar]).reshape(-1), 5).astype(float)
                # Fixed cutoff in Hz and increasing symbol rate produce more relative memory.
                sos = butter(2, .7e6, fs=rate*10, output='sos')
                raw = sosfilt(sos, np.tile(tx, 3))
                raw += rng.normal(0, .02, len(raw))
                meta = dict(capture_id=f'synthetic_{split}_{rate}_{index}',
                            session_id=f'synthetic_{split}', condition_id='synthetic_lowpass',
                            split=split, synthetic=True)
                savemat(folder / f'{index}.mat', dict(metadata_json=json.dumps(meta), tx_bits=y,
                        tx_samples=tx, rx_raw=raw, rx_aligned=raw[:len(tx)], sps=10,
                        bit_rate=rate, tx_sample_rate=rate*10, rx_sample_rate=rate*10,
                        status='ok', sync_mode='assisted_full_tx'))
    return out


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--frames', type=int, default=3)
    parser.add_argument('--bits', type=int, default=128)
    parser.add_argument('--seed', type=int, default=120)
    args = parser.parse_args()
    generate(args.out, args.frames, args.bits, args.seed)
