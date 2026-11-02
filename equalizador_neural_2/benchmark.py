"""Real-waveform benchmark per rate: integrator, template, FFE/ridge, CNN and DFE."""
import argparse
import csv
import json
from pathlib import Path
import time

import shared  # noqa: F401
import numpy as np
from benchmark_detectors import benchmark as reference_benchmark, paired_session_bootstrap
from offline_dataset import load_campaign, require_independent_splits
from pipeline import fit_ridge, windows
from reprocess_captures import file_sha256, vector_hash
from campaign import snapshot, write_csv, write_json


def feedback_features(bits, taps):
    history = np.pad(2*np.asarray(bits)-1, (taps, 0))
    return np.array([history[taps+i-taps:taps+i][::-1] for i in range(len(bits))])


def dfe_predict(features, weights, taps):
    """Closed-loop decisions: never consume unknown test/validation TX bits."""
    history = np.zeros(taps)
    predicted = np.empty(len(features), dtype=int)
    width = features.shape[1]
    for i, row in enumerate(features):
        decision = row @ weights[:width] + history @ weights[width:-1] + weights[-1]
        predicted[i] = int(decision > 0)
        history[1:] = history[:-1].copy()
        history[0] = 2*predicted[i]-1
    return predicted


def run(data, out, epochs=20, context=2, feedback=3, seed=42):
    if feedback < 1 or context < 0 or epochs < 1 or seed < 0:
        raise ValueError('Invalid context, feedback, epochs or seed')
    captures, provenance = load_campaign(data)
    sessions = require_independent_splits(captures)
    synthetic = [bool(c['meta'].get('synthetic', False)) for c in captures]
    if any(synthetic) and not all(synthetic):
        raise ValueError('Do not mix synthetic fixtures and physical captures in this benchmark')
    splits = {s: [c for c in captures if c['meta']['split'] == s and c['status'] == 'ok']
              for s in ('train', 'val', 'test')}
    if any(not group for group in splits.values()):
        raise ValueError('Each split requires accepted captures')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    manifest = dict(state='running', datasets=provenance, sessions=sessions,
                    synthetic_only=all(synthetic),
                    seed=seed, context=context, feedback=feedback, epochs=epochs,
                    bit_rate=captures[0]['bit_rate'], code_sha256=snapshot(out),
                    protocol='No added AWGN. Per-rate models; full TX-assisted synchronization.',
                    dfe='Teacher forcing only on training; recursive validation/test; reset per frame. '
                        'Same feedforward window as ridge/CNN, with additional past decisions.')
    write_json(out / 'manifest.json', manifest)
    try:
        reference_benchmark(data, out / 'reference', augmentation=(), validation_ratios=(),
                            evaluation_ratios=(), seed=seed, epochs=epochs, context=context, realizations=1)
        config = json.loads((out / 'reference/model_config.json').read_text())
        mean, scale = config['mean'], config['scale']

        def features(c):
            return (windows(c['x'], c['sps'], context)-mean)/scale

        x = np.concatenate([np.column_stack([features(c), feedback_features(c['y'], feedback)])
                            for c in splits['train']])
        y = np.concatenate([c['y'] for c in splits['train']])
        candidates = []
        for alpha in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1.):
            weights = fit_ridge(x, y, alpha)
            errors = sum(np.sum(dfe_predict(features(c), weights, feedback) != c['y']) for c in splits['val'])
            candidates.append((errors/sum(len(c['y']) for c in splits['val']), alpha, weights))
        val_ber, alpha, weights = min(candidates, key=lambda item: item[0])
        np.savez(out / 'dfe.npz', weights=weights, feedback=feedback, context=context, mean=mean, scale=scale)
        write_json(out / 'dfe_config.json', dict(alpha=alpha, validation_ber=float(val_ber)))
        with (out / 'reference/frames.csv').open(encoding='utf-8') as stream:
            rows = list(csv.DictReader(stream))
        for row in rows:
            row['ratio_db'] = None
            row['bit_errors'] = int(row['bit_errors']) if row['bit_errors'] else None
            row['bits_evaluated'] = int(row['bits_evaluated'])
            row['detector_seconds'] = float(row['detector_seconds'])
            row['feature_seconds'] = float(row['feature_seconds'])
        for c in (c for c in captures if c['meta']['split'] == 'test'):
            accepted = c['status'] == 'ok'
            feature_seconds, detector_seconds, errors = 0., 0., None
            if accepted:
                start = time.perf_counter()
                fx = features(c)
                feature_seconds = time.perf_counter()-start
                start = time.perf_counter()
                predicted = dfe_predict(fx, weights, feedback)
                detector_seconds = time.perf_counter()-start
                errors = int(np.sum(predicted != c['y']))
            rows.append(dict(capture_id=c['meta']['capture_id'], session_id=c['meta']['session_id'],
                             condition_id=c['meta']['condition_id'], source_sha256=c['source_sha256'],
                             ratio_db=None, realization=0, method='dfe', status=c['status'],
                             bits_evaluated=len(c['y']) if accepted else 0, bit_errors=errors,
                             detector_seconds=detector_seconds, feature_seconds=feature_seconds,
                             variant_sha256=vector_hash(c['x']) if accepted else ''))
        curves = []
        for method in sorted({r['method'] for r in rows}):
            group = [r for r in rows if r['method'] == method]
            good = [r for r in group if r['status'] == 'ok']
            bits = sum(r['bits_evaluated'] for r in good)
            errors = sum(r['bit_errors'] for r in good)
            curves.append(dict(method=method, bit_rate=captures[0]['bit_rate'], attempts=len(group),
                               accepted=len(good), bits=bits, errors=errors, ber=errors/bits,
                               fer=sum(r['bit_errors'] > 0 for r in good)/len(good),
                               exact_frame_fraction=sum(r['bit_errors'] == 0 for r in good)/len(group),
                               detector_seconds=sum(r['detector_seconds'] for r in good)))
        write_csv(out / 'frames.csv', rows)
        write_csv(out / 'curves.csv', curves)
        write_json(out / 'summary.json', dict(curves=curves,
                   paired_bootstrap=[paired_session_bootstrap(rows, None, method)
                                     for method in ('integrator', 'matched_template', 'linear_ridge', 'dfe')],
                   warning='Bit_rate is nominal, not measured goodput. Timing excludes acquisition. '
                           'Models are trained separately per rate, not a cross-rate generalization result. '
                           'Few sessions remain statistically fragile. No causal streaming claim.'))
        _, after = load_campaign(data)
        if after != provenance:
            raise ValueError('Dataset changed during benchmark')
        manifest['state'] = 'complete'
        manifest['outputs_sha256'] = {p.relative_to(out).as_posix(): file_sha256(p)
                                      for p in out.rglob('*') if p.is_file() and p != out/'manifest.json'}
    except Exception as exc:
        manifest.update(state='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        write_json(out / 'manifest.json', manifest)
    return curves


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', nargs='+', required=True, help='Audited roots for ONE rate, with independent splits')
    parser.add_argument('--out', required=True)
    parser.add_argument('--epochs', type=int, default=20)
    parser.add_argument('--context', type=int, default=2)
    parser.add_argument('--feedback', type=int, default=3)
    parser.add_argument('--seed', type=int, default=42)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.data, args.out, args.epochs, args.context, args.feedback, args.seed), indent=2))
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Error: {exc}\n')
