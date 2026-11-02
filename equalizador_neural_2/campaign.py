"""Audit raw MATLAB captures by rate and characterize real Manchester reception."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import csv
import json
from pathlib import Path
import tempfile
from zipfile import ZipFile

import shared
import numpy as np
from scipy.io import loadmat
from scipy.signal import csd, welch
from capture_sync import manchester_bits
from offline_dataset import load_audited_dataset
from reprocess_captures import file_sha256, reprocess_archive, validate_capture


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def write_csv(path, rows):
    with Path(path).open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def snapshot(out):
    root = Path(__file__).resolve().parent
    folder = out / 'code'
    folder.mkdir()
    for source in [*root.glob('*.py'), *shared.SOURCE.glob('*.py')]:
        target = folder / ('new_' + source.name if source.parent == root else 'proposal2_' + source.name)
        target.write_bytes(source.read_bytes())
    return {p.name: file_sha256(p) for p in folder.iterdir()}


def prepare(directories, out):
    """Validate before output creation; preserve input bytes in per-rate ZIPs."""
    groups, records, ids, sessions = defaultdict(list), [], set(), {}
    for directory in directories:
        root = Path(directory)
        if not root.is_dir():
            raise ValueError(f'Not a capture directory: {root}')
        for path in sorted(root.rglob('*.mat')):
            if path.is_symlink():
                raise ValueError('Capture symlinks are not supported')
            data = loadmat(path, simplify_cells=True)
            meta, _, _, _, sps = validate_capture(data)
            identity = meta['capture_id'].casefold()
            if identity in ids:
                raise ValueError('Duplicate capture ID across source directories')
            ids.add(identity)
            session, split = meta['session_id'], meta['split']
            if session in sessions and sessions[session] != split:
                raise ValueError('Session crosses splits')
            sessions[session] = split
            rate = float(data['bit_rate'])
            if rate != int(rate):
                raise ValueError('This campaign requires integer bit rates in bit/s')
            key = f'rate_{int(rate)}_sps_{sps}'
            digest = file_sha256(path)
            records.append(dict(path=str(path.resolve()), sha256=digest, rate_key=key))
            groups[key].append((path, meta['capture_id'], digest))
    if not records:
        raise ValueError('No captures found')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    manifest = dict(state='running', started_at_utc=datetime.now(timezone.utc).isoformat(),
                    inputs=records, datasets={}, code_sha256=snapshot(out))
    write_json(out / 'manifest.json', manifest)
    summaries = []
    try:
        for key, members in sorted(groups.items()):
            # Staging exists only inside this new output; originals are never changed.
            with tempfile.TemporaryDirectory(dir=out) as staging:
                archive_path = Path(staging) / 'captures.zip'
                with ZipFile(archive_path, 'w') as archive:
                    for path, identity, digest in members:
                        if file_sha256(path) != digest:
                            raise ValueError('Input changed during preparation')
                        archive.write(path, identity + '.mat')
                reprocess_archive(archive_path, out / key)
            summary = characterize(out / key, out / key / 'characterization')
            summaries.extend([dict(rate_key=key, bit_rate=int(key.split('_')[1]), **row) for row in summary])
            manifest['datasets'][key] = key
        write_csv(out / 'characterization.csv', summaries)
        for record in records:
            if file_sha256(record['path']) != record['sha256']:
                raise ValueError('Input changed during preparation')
        manifest['state'] = 'complete'
        manifest['outputs_sha256'] = {p.relative_to(out).as_posix(): file_sha256(p)
                                      for p in out.rglob('*') if p.is_file() and p != out/'manifest.json'}
    except Exception as exc:
        manifest.update(state='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        write_json(out / 'manifest.json', manifest)
    return manifest


def characterize(data, out):
    captures, provenance = load_audited_dataset(data)
    rows, spectra = [], []
    for c in captures:
        raw = c['raw']
        row = dict(capture_id=c['meta']['capture_id'], session_id=c['meta']['session_id'],
                   split=c['meta']['split'], bit_rate=c['bit_rate'], status=c['status'],
                   bits=0, errors=None, sync_score=c['sync_score'],
                   adc_rail_fraction=float(np.mean((raw <= -128) | (raw >= 127))) if len(raw) else None,
                   signed_margin_q05=None, signed_margin_median=None)
        if c['status'] == 'ok':
            x, y, sps = c['x'], c['y'], c['sps']
            frame = x.reshape(-1, sps)
            margins = (2*y-1) * (frame[:, :sps//2].mean(1) - frame[:, sps//2:].mean(1))
            row.update(bits=len(y), errors=int(np.sum(manchester_bits(x, sps) != y)),
                       signed_margin_q05=float(np.quantile(margins, .05)),
                       signed_margin_median=float(np.median(margins)))
            if len(x) >= 64:
                fs = sps * c['bit_rate']
                n = min(512, len(x)//2)
                f, pxx = welch(c['tx'], fs=fs, nperseg=n)
                _, pyy = welch(x, fs=fs, nperseg=n)
                _, pxy = csd(c['tx'], x, fs=fs, nperseg=n)
                support = pxx > pxx.max()*10**(-35/10)
                h = np.divide(pxy, pxx, out=np.zeros_like(pxy), where=support)
                coherence = np.clip(abs(pxy)**2 / np.maximum(pxx*pyy, np.finfo(float).tiny), 0, 1)
                reference = max(float(np.max(abs(h))), np.finfo(float).tiny)
                for i in range(len(f)):
                    spectra.append(dict(capture_id=row['capture_id'], frequency_hz=float(f[i]),
                                        tx_supported=bool(support[i]), coherence=float(coherence[i]),
                                        relative_gain_db=float(20*np.log10(max(abs(h[i])/reference, 1e-15)))
                                        if support[i] else None))
        rows.append(row)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    write_csv(out / 'frames.csv', rows)
    if spectra:
        write_csv(out / 'spectra.csv', spectra)
    groups = defaultdict(list)
    for row in rows:
        groups[(row['session_id'], row['split'])].append(row)
    summary = []
    for (session, split), group in groups.items():
        bits = sum(r['bits'] for r in group)
        good = [r for r in group if r['status'] == 'ok']
        errors = sum(r['errors'] for r in good)
        summary.append(dict(session_id=session, split=split, attempts=len(group), accepted=len(good),
                            bits=bits, errors=errors, ber=errors/bits if bits else None,
                            fer=sum(r['errors'] > 0 for r in good)/len(good) if good else None))
    write_json(out / 'summary.json', dict(dataset=provenance, sessions=summary,
               warning='Exploratory TX-assisted characterization. Spectra are normalized estimates, '
                       'not calibrated physical bandwidth/SNR; no automatic 3 dB cutoff. '
                       'Failed alignment BER is unknown; ADC rails do not diagnose analog saturation.'))
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', nargs='+', required=True, help='Directories containing only raw capture MAT files')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.out)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Error: {exc}\n')
    print(json.dumps(result, indent=2))
