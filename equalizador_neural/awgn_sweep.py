"""Exploratory integrator sweeps with post-alignment or pre-sync numerical AWGN."""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import json
from pathlib import Path

import numpy as np

from awgn import NOISE_VERSION, add_awgn, frame_error_probability, integrator_error_probabilities
from capture_sync import manchester_bits, synchronize_samples
from offline_dataset import load_audited_dataset
from reprocess_captures import file_sha256, implementation_info, vector_hash


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, allow_nan=False)+'\n', encoding='utf-8')


def snapshot_code(out, names):
    code = Path(out)/'code'
    code.mkdir()
    for name in names:
        with (code/name).open('xb') as stream:
            stream.write((Path(__file__).parent/name).read_bytes())
    return {name: file_sha256(code/name) for name in names}


def summarize_level(rows, ratio_db):
    good = [r for r in rows if r['status'] == 'ok']
    bits = sum(r['bits_evaluated'] for r in good)
    errors = sum(r['bit_errors'] for r in good)
    realizations = sorted({r['realization'] for r in good})
    realization_bers = []
    for realization in realizations:
        selected = [r for r in good if r['realization'] == realization]
        realization_bers.append(sum(r['bit_errors'] for r in selected)/sum(r['bits_evaluated'] for r in selected))
    analytical = bool(good) and all(r['expected_bit_errors'] is not None for r in good)
    return dict(ratio_db=ratio_db, attempts=len(rows), accepted=len(good),
                rejected=len(rows)-len(good), bits_evaluated=bits, bit_errors=errors,
                ber=errors/bits if bits else None,
                fer_given_alignment=sum(r['bit_errors'] > 0 for r in good)/len(good) if good else None,
                exact_frame_delivery=sum(r['bit_errors'] == 0 for r in good)/len(rows),
                expected_conditional_ber=sum(r['expected_bit_errors'] for r in good)/bits if analytical else None,
                expected_conditional_fer=float(np.mean([r['expected_fer'] for r in good])) if analytical else None,
                conditional_mc_ber_standard_error=float(np.sqrt(sum(r['error_count_variance'] for r in good))/bits)
                                                   if analytical else None,
                ber_std_across_noise_realizations=float(np.std(realization_bers, ddof=1))
                                                 if len(realization_bers) > 1 else None,
                physical_captures=len({r['capture_id'] for r in rows}),
                note='BER/FER conditional on accepted alignment; replicas are not new physical sessions.')


def plot_curves(curves, out, point):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    noisy = [r for r in curves if r['ratio_db'] is not None]
    for name, measured, expected in [('ber', 'ber', 'expected_conditional_ber'),
                                     ('fer', 'fer_given_alignment', 'expected_conditional_fer')]:
        fig, axis = plt.subplots(figsize=(8, 5))
        axis.plot([r['ratio_db'] for r in noisy], [r[measured] for r in noisy], 'o-', label='Monte Carlo integrator')
        if any(r[expected] is not None for r in noisy):
            axis.plot([r['ratio_db'] for r in noisy], [r[expected] for r in noisy], '--', label='Exact conditional expectation')
        max_bits = max(r['bits_evaluated'] for r in noisy)
        axis.set_yscale('symlog', linthresh=1/max(1, max_bits))
        axis.set_xlabel('Captured AC power / added noise variance (dB; not physical SNR)')
        axis.set_ylabel(name.upper())
        axis.set_title(f'Pilot + numerical AWGN: {point} (TX-assisted)')
        axis.grid(True, which='both', alpha=.3)
        axis.legend()
        fig.tight_layout()
        for extension in ('png', 'svg'):
            fig.savefig(Path(out)/f'{name}.{extension}', dpi=160)
        plt.close(fig)
    fig, axis = plt.subplots(figsize=(8, 4))
    axis.plot([r['ratio_db'] for r in noisy], [r['accepted']/r['attempts'] for r in noisy], 'o-', label='Accepted alignment')
    axis.plot([r['ratio_db'] for r in noisy], [r['exact_frame_delivery'] for r in noisy], 's-', label='Exact frame / all attempts (offline TX comparison)')
    axis.set_xlabel('Captured AC power / added noise variance (dB; not physical SNR)')
    axis.set_ylabel('Fraction')
    axis.set_ylim(-.03, 1.03)
    axis.grid(True, alpha=.3)
    axis.legend()
    fig.tight_layout()
    for extension in ('png', 'svg'):
        fig.savefig(Path(out)/f'availability.{extension}', dpi=160)
    plt.close(fig)


def run_sweep(data, out, ratios_db=None, realizations=20, seed=42, plots=True, point='post-alignment'):
    ratios = [float(v) for v in (ratios_db if ratios_db is not None else range(-20, 21, 5))]
    if not ratios or len(set(ratios)) != len(ratios) or any(not np.isfinite(v) or abs(v) > 100 for v in ratios):
        raise ValueError('provide distinct finite added-noise ratios within [-100, 100]')
    if not isinstance(realizations, int) or realizations < 1 or not isinstance(seed, int) or seed < 0:
        raise ValueError('positive realization count and nonnegative integer seed required')
    if point not in ('post-alignment', 'pre-synchronization'):
        raise ValueError('unsupported noise injection point')
    captures, provenance = load_audited_dataset(data)
    if not any(c['status'] == 'ok' for c in captures):
        raise ValueError('no accepted captures to evaluate')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    manifest = dict(state='running', started_at_utc=datetime.now(timezone.utc).isoformat(),
                    dataset=provenance, noise_version=NOISE_VERSION, ratios_db=sorted(ratios),
                    realizations=realizations, seed=seed, generator='NumPy PCG64 + SHA256 keyed identity',
                    noise_variance='expected sigma^2; draws are not centered or RMS-normalized',
                    point=point,
                    preprocessing='post: fixed alignment, no renormalization; pre: raw + noise, peak normalization, resynchronize',
                    clipping='No clipping or ADC requantization in either numerical experiment.',
                    scope='Exploratory one/multiple-session fixed-waveform Monte Carlo; not physical noise injection',
                    uncertainty='MC variability conditional on these waveforms, not session-level confidence',
                    implementation=implementation_info(),
                    code_sha256=snapshot_code(out, ('awgn.py', 'awgn_sweep.py', 'offline_dataset.py',
                                                   'capture_sync.py', 'reprocess_captures.py')))
    write_json(out/'manifest.json', manifest)
    curves = []
    try:
        with (out/'frames.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = None
            for ratio in [None]+sorted(ratios):
                rows = []
                for capture in captures:
                    for realization in range(1 if ratio is None else realizations):
                        row = dict(capture_id=capture['meta']['capture_id'],
                                   session_id=capture['meta']['session_id'], split=capture['meta']['split'],
                                   condition_id=capture['meta']['condition_id'],
                                   source_sha256=capture['source_sha256'], ratio_db=ratio,
                                   realization=realization, status=capture['status'],
                                   source_status=capture['status'], injection_point=point,
                                   sync_score=capture['sync_score'], sync_reason='fixed_original_alignment',
                                   bits_evaluated=0, bit_errors=None, expected_bit_errors=None,
                                   expected_fer=None, error_count_variance=None, sigma=None,
                                   captured_ac_power=None, expected_noise_power=None,
                                   realized_noise_power=None, noise_mean=None, noise_seed_hex='', variant_sha256='')
                        if capture['status'] == 'ok':
                            base = capture['x'] if point == 'post-alignment' else capture['raw']
                            noisy, info = add_awgn(base, row['capture_id'], row['source_sha256'],
                                                   ratio, seed, realization,
                                                   stream=None if point == 'post-alignment' else point)
                            row['variant_sha256'] = vector_hash(noisy)
                            if point == 'pre-synchronization':
                                peak = float(np.max(abs(noisy)))
                                noisy, sync = synchronize_samples(capture['tx'], noisy/peak, capture['sync_threshold'])
                                row.update(sync_score=sync['score'], sync_reason=sync['reason'],
                                           status='ok' if sync['accepted'] else 'error')
                            else:
                                probabilities = integrator_error_probabilities(capture['x'], capture['y'],
                                                                               capture['sps'], info['sigma'])
                                row.update(expected_bit_errors=float(probabilities.sum()),
                                           expected_fer=frame_error_probability(probabilities),
                                           error_count_variance=float(np.sum(probabilities*(1-probabilities))))
                            if row['status'] == 'ok':
                                row.update(bits_evaluated=len(capture['y']),
                                           bit_errors=int(np.sum(manchester_bits(noisy, capture['sps']) != capture['y'])))
                            row.update({k: info[k] for k in ('sigma', 'captured_ac_power', 'expected_noise_power',
                                                            'realized_noise_power', 'noise_mean', 'noise_seed_hex')})
                        if writer is None:
                            writer = csv.DictWriter(stream, fieldnames=list(row))
                            writer.writeheader()
                        writer.writerow(row)
                        rows.append(row)
                curves.append(summarize_level(rows, ratio))
        summary = dict(curves=curves, unique_physical_captures=len(captures),
                       unique_physical_bits=sum(len(c['y']) for c in captures),
                       sessions=dict(Counter(c['meta']['session_id'] for c in captures)),
                       splits=dict(Counter(c['meta']['split'] for c in captures)),
                       injection_point=point,
                       warning='No CNN trained; no independent-session performance claim; ratios are not physical SNR.')
        write_json(out/'summary.json', summary)
        with (out/'curves.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(curves[0]))
            writer.writeheader()
            writer.writerows(curves)
        if plots:
            plot_curves(curves, out, point)
        # Verify sources again rather than assuming the run did not alter them.
        _, end_provenance = load_audited_dataset(data)
        if provenance != end_provenance:
            raise ValueError('source dataset changed during sweep')
        manifest.update(state='complete', outputs_sha256={p.relative_to(out).as_posix(): file_sha256(p) for p in out.rglob('*')
                                                        if p.is_file() and p.name != 'manifest.json'})
    except Exception as exc:
        manifest.update(state='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        manifest['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
        write_json(out/'manifest.json', manifest)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True, help='Audited reprocessing root, not its captures/ subdirectory')
    parser.add_argument('--out', required=True)
    parser.add_argument('--ratios-db', type=float, nargs='+')
    parser.add_argument('--realizations', type=int, default=20)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--no-plots', action='store_true')
    parser.add_argument('--point', choices=['post-alignment', 'pre-synchronization'], default='post-alignment')
    args = parser.parse_args()
    result = run_sweep(args.data, args.out, args.ratios_db, args.realizations, args.seed, not args.no_plots, args.point)
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
