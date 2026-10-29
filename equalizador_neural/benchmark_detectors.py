"""Guarded AWGN benchmark for independent sessions; never repartitions a pilot."""
import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch import nn

from awgn import NOISE_VERSION, add_awgn
from awgn_sweep import snapshot_code, write_json
from capture_sync import manchester_bits
from offline_dataset import load_campaign, require_independent_splits
from pipeline import Detector, fit_ridge, neural_bits, ridge_bits, windows
from reprocess_captures import file_sha256, implementation_info, vector_hash


def fit_template(captures):
    """Single-bit class-mean matched template; not a full FIR/DFE equalizer."""
    x = np.concatenate([c['x'].reshape(-1, c['sps']) for c in captures if c['status'] == 'ok'])
    y = np.concatenate([c['y'] for c in captures if c['status'] == 'ok'])
    if len(np.unique(y)) != 2:
        raise ValueError('both bit classes required in training')
    low, high = x[y == 0].mean(0), x[y == 1].mean(0)
    weights = high-low
    return weights, float(-weights @ ((high+low)/2))


def template_bits(samples, sps, weights, intercept):
    return (samples.reshape(-1, sps) @ weights+intercept > 0).astype(int)


def noise_views(captures, ratios, realizations, seed):
    for c in captures:
        if c['status'] != 'ok':
            continue
        for ratio in [None]+list(ratios):
            for realization in range(1 if ratio is None else realizations):
                noisy, _ = add_awgn(c['x'], c['meta']['capture_id'], c['source_sha256'],
                                    ratio, seed, realization)
                yield c, noisy


def feature_arrays(captures, context, ratios, realizations, seed):
    views = list(noise_views(captures, ratios, realizations, seed))
    if not views:
        raise ValueError('split has no accepted captures')
    return (np.concatenate([windows(noisy, c['sps'], context) for c, noisy in views]),
            np.concatenate([c['y'] for c, _ in views]))


def paired_session_bootstrap(rows, ratio, baseline, repeats=2000, seed=901):
    selected = [r for r in rows if r['ratio_db'] == ratio and r['status'] == 'ok']
    sessions = sorted({r['session_id'] for r in selected})
    differences = []
    for session in sessions:
        rates = {}
        for method in ('cnn', baseline):
            group = [r for r in selected if r['session_id'] == session and r['method'] == method]
            if group:
                rates[method] = sum(r['bit_errors'] for r in group)/sum(r['bits_evaluated'] for r in group)
        if len(rates) == 2:
            differences.append(rates['cnn']-rates[baseline])
    result = dict(ratio_db=ratio, baseline=baseline, sessions=len(differences),
                  mean_session_ber_difference=float(np.mean(differences)) if differences else None,
                  percentile95=None, warning='Session-level paired bootstrap; few sessions remain fragile.')
    if len(differences) >= 2:
        rng = np.random.Generator(np.random.PCG64(seed))
        draws = rng.choice(differences, size=(repeats, len(differences)), replace=True).mean(1)
        result['percentile95'] = np.quantile(draws, [.025, .975]).tolist()
    return result


def benchmark(data, out, augmentation=(), validation_ratios=(-6., -2., 2.),
              evaluation_ratios=(-8., -4., 0., 4., 8.), seed=42, epochs=20,
              context=2, realizations=5, data_seed=314159, evaluation_seed=271828):
    if epochs < 1 or context < 0 or realizations < 1 or seed < 0:
        raise ValueError('invalid training parameters')
    for levels in (augmentation, validation_ratios, evaluation_ratios):
        if len(set(levels)) != len(levels) or any(not np.isfinite(v) or abs(v) > 100 for v in levels):
            raise ValueError('noise ratios must be distinct and within [-100, 100] dB')
    captures, provenance = load_campaign(data)
    sessions = require_independent_splits(captures)  # Before fitting or creating output.
    splits = {key: [c for c in captures if c['meta']['split'] == key] for key in sessions}
    for split, group in splits.items():
        if not any(c['status'] == 'ok' for c in group):
            raise ValueError(f'{split}: no accepted captures')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(1)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)
    manifest = dict(state='running', started_at_utc=datetime.now(timezone.utc).isoformat(),
                    datasets=provenance, sessions=sessions, noise_version=NOISE_VERSION,
                    augmentation_ratios=list(augmentation), validation_ratios=list(validation_ratios),
                    evaluation_ratios=list(evaluation_ratios), seed=seed, data_seed=data_seed,
                    validation_seed=data_seed+1, evaluation_seed=evaluation_seed,
                    train_noise_realizations=1, validation_noise_realizations=1,
                    evaluation_noise_realizations=realizations, epochs=epochs, context=context,
                    information='All methods share fixed TX-assisted alignment and paired noisy waveforms.',
                    training='Fixed common noise views for ridge/CNN; mean/scale from clean training only.',
                    limitation='Matched template is a class-mean bit detector, not a full FIR/DFE equalizer.',
                    synthetic_only=all(c['meta'].get('synthetic', False) for c in captures),
                    implementation=implementation_info(), torch=torch.__version__,
                    code_sha256=snapshot_code(out, (
                        'benchmark_detectors.py', 'awgn.py', 'awgn_sweep.py', 'offline_dataset.py',
                        'pipeline.py', 'capture_sync.py', 'reprocess_captures.py')))
    write_json(out/'manifest.json', manifest)
    try:
        clean_train, _ = feature_arrays(splits['train'], context, (), 1, data_seed)
        mean, scale = float(clean_train.mean()), max(float(clean_train.std()), 1e-8)
        x, y = feature_arrays(splits['train'], context, augmentation, 1, data_seed)
        vx, vy = feature_arrays(splits['val'], context, validation_ratios, 1, data_seed+1)
        x, vx = (x-mean)/scale, (vx-mean)/scale
        if len(np.unique(y)) != 2:
            raise ValueError('both bit classes required in training')
        candidates = []
        for alpha in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1.):
            weights = fit_ridge(x, y, alpha)
            candidates.append((float(np.mean(ridge_bits(vx, weights) != vy)), alpha, weights))
        ridge_val, alpha, ridge_weights = min(candidates, key=lambda item: item[0])
        template_weights, intercept = fit_template(splits['train'])
        model = Detector(x.shape[1])
        optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
        dataset = torch.utils.data.TensorDataset(torch.from_numpy(x), torch.from_numpy(y.astype(np.float32)))
        loader = torch.utils.data.DataLoader(dataset, batch_size=256, shuffle=True,
                                            generator=torch.Generator().manual_seed(seed))
        best, history = float('inf'), []
        for epoch in range(epochs):
            model.train()
            loss_sum = 0.
            for bx, by in loader:
                optimizer.zero_grad()
                loss = nn.functional.binary_cross_entropy_with_logits(model(bx), by)
                loss.backward()
                optimizer.step()
                loss_sum += loss.item()*len(by)
            val_ber = float(np.mean(neural_bits(model, vx, 1024) != vy))
            history.append(dict(epoch=epoch+1, loss=loss_sum/len(y), validation_ber=val_ber))
            if val_ber < best:
                best = val_ber
                torch.save(model.state_dict(), out/'cnn.pt')
        np.savez(out/'classical.npz', ridge_weights=ridge_weights,
                 template_weights=template_weights, template_intercept=intercept)
        write_json(out/'model_config.json', dict(mean=mean, scale=scale, context=context,
                   ridge_alpha=alpha, ridge_validation_ber=ridge_val, cnn_validation_ber=best,
                   width=x.shape[1], validation_objective='Pooled BER over fixed clean and noisy validation views',
                   history=history, training_capture_ids=[c['meta']['capture_id'] for c in splits['train']]))
        model.load_state_dict(torch.load(out/'cnn.pt', map_location='cpu', weights_only=True))
        # Warmup is not counted as inference time.
        neural_bits(model, np.zeros((1, x.shape[1]), np.float32), 1024)
        rows = []
        for ratio in [None]+list(evaluation_ratios):
            for c in splits['test']:
                for realization in range(1 if ratio is None else realizations):
                    noisy, features, variant_hash = None, None, ''
                    feature_seconds = 0.
                    if c['status'] == 'ok':
                        noisy, _ = add_awgn(c['x'], c['meta']['capture_id'], c['source_sha256'],
                                            ratio, evaluation_seed, realization)
                        variant_hash = vector_hash(noisy)
                        start = time.perf_counter()
                        features = (windows(noisy, c['sps'], context)-mean)/scale
                        feature_seconds = time.perf_counter()-start
                    for method in ('integrator', 'matched_template', 'linear_ridge', 'cnn'):
                        errors, seconds = None, 0.
                        if noisy is not None:
                            start = time.perf_counter()
                            if method == 'integrator':
                                predicted = manchester_bits(noisy, c['sps'])
                            elif method == 'matched_template':
                                predicted = template_bits(noisy, c['sps'], template_weights, intercept)
                            elif method == 'linear_ridge':
                                predicted = ridge_bits(features, ridge_weights)
                            else:
                                predicted = neural_bits(model, features, 1024)
                            seconds = time.perf_counter()-start
                            errors = int(np.sum(predicted != c['y']))
                        rows.append(dict(capture_id=c['meta']['capture_id'], session_id=c['meta']['session_id'],
                                         condition_id=c['meta']['condition_id'], source_sha256=c['source_sha256'],
                                         ratio_db=ratio, realization=realization, method=method, status=c['status'],
                                         bits_evaluated=len(c['y']) if noisy is not None else 0, bit_errors=errors,
                                         detector_seconds=seconds, feature_seconds=feature_seconds,
                                         variant_sha256=variant_hash))
        curves = []
        for ratio in [None]+list(evaluation_ratios):
            for method in ('integrator', 'matched_template', 'linear_ridge', 'cnn'):
                group = [r for r in rows if r['ratio_db'] == ratio and r['method'] == method]
                good = [r for r in group if r['status'] == 'ok']
                bits = sum(r['bits_evaluated'] for r in good)
                errors = sum(r['bit_errors'] for r in good)
                curves.append(dict(ratio_db=ratio, method=method, attempts=len(group),
                                   accepted=len(good), bits_evaluated=bits, bit_errors=errors,
                                   ber=errors/bits if bits else None,
                                   fer_given_alignment=sum(r['bit_errors'] > 0 for r in good)/len(good) if good else None,
                                   detector_seconds=sum(r['detector_seconds'] for r in good)))
        for filename, table in [('frames.csv', rows), ('curves.csv', curves)]:
            with (out/filename).open('w', newline='', encoding='utf-8') as stream:
                writer = csv.DictWriter(stream, fieldnames=list(table[0]))
                writer.writeheader()
                writer.writerows(table)
        write_json(out/'summary.json', dict(curves=curves,
                   paired_bootstrap=[paired_session_bootstrap(rows, ratio, baseline)
                                     for ratio in [None]+list(evaluation_ratios)
                                     for baseline in ('integrator', 'matched_template', 'linear_ridge')],
                   warning='Synthetic smoke tests do not establish real neural gain; one-session pilots cannot run here.'))
        _, end_provenance = load_campaign(data)
        if provenance != end_provenance:
            raise ValueError('source data changed during benchmark')
        manifest.update(state='complete', outputs_sha256={p.relative_to(out).as_posix(): file_sha256(p) for p in out.rglob('*')
                                                        if p.is_file() and p.name != 'manifest.json'})
    except Exception as exc:
        manifest.update(state='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        manifest['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
        write_json(out/'manifest.json', manifest)
    return curves


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', nargs='+', required=True, help='Audited roots from independent sessions')
    parser.add_argument('--out', required=True)
    parser.add_argument('--augmentation-ratios-db', nargs='*', type=float, default=[])
    parser.add_argument('--validation-ratios-db', nargs='+', type=float, default=[-6, -2, 2])
    parser.add_argument('--evaluation-ratios-db', nargs='+', type=float, default=[-8, -4, 0, 4, 8])
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--epochs', type=int, default=20)
    parser.add_argument('--context', type=int, default=2)
    parser.add_argument('--realizations', type=int, default=5)
    args = parser.parse_args()
    try:
        curves = benchmark(args.data, args.out, args.augmentation_ratios_db,
                           args.validation_ratios_db, args.evaluation_ratios_db,
                           args.seed, args.epochs, args.context, args.realizations)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Error: {exc}\n')
    print(json.dumps(curves, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
