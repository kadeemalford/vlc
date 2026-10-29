"""Reprocess a capture ZIP without extraction, hardware access, or source changes."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import csv
import hashlib
from io import BytesIO
import json
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import time
from zipfile import BadZipFile, ZipFile

import numpy as np
import scipy
from scipy.io import loadmat, savemat
from scipy.io.matlab import MatReadError

from capture_sync import SYNC_METHOD, manchester_bits, real_vector, synchronize_samples


TOOL_VERSION = '1.0'
MAX_MEMBER_BYTES = 32*1024**2
MAX_ARCHIVE_BYTES = 256*1024**2
CAPTURE_ID = re.compile(r'^[A-Za-z0-9_-]+$')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''):
            digest.update(block)
    return digest.hexdigest()


def vector_hash(array):
    return sha256(np.asarray(array, dtype='<f8').reshape(-1).tobytes())


def scalar(data, key):
    value = np.asarray(data[key])
    if value.size != 1 or value.dtype.kind not in 'biuf':
        raise ValueError(f'{key}: expected a real scalar')
    value = float(value.reshape(-1)[0])
    if not np.isfinite(value):
        raise ValueError(f'{key}: expected a finite scalar')
    return value


def text(value):
    """scipy simplifies MATLAB empty char arrays to empty ndarrays."""
    if isinstance(value, str):
        return value
    array = np.asarray(value)
    if not array.size:
        return ''
    if array.size == 1 and array.dtype.kind in 'US':
        return str(array.reshape(-1)[0])
    raise ValueError('expected a MATLAB character string')


def validate_capture(data):
    required = ('metadata_json', 'tx_bits', 'tx_samples', 'rx_raw', 'rx_aligned',
                'sps', 'bit_rate', 'tx_sample_rate', 'rx_sample_rate', 'status', 'sync_mode')
    missing = [key for key in required if key not in data]
    if missing:
        raise ValueError(f'missing capture fields: {", ".join(missing)}')
    meta = json.loads(text(data['metadata_json']))
    if not isinstance(meta, dict):
        raise ValueError('metadata_json must contain an object')
    for key in ('capture_id', 'session_id', 'condition_id', 'split'):
        if not isinstance(meta.get(key), str) or not meta[key]:
            raise ValueError(f'invalid metadata field: {key}')
    if not CAPTURE_ID.fullmatch(meta['capture_id']):
        raise ValueError('unsafe capture_id')
    if meta['split'] not in ('train', 'val', 'test'):
        raise ValueError('invalid split')
    if text(data['sync_mode']) != 'assisted_full_tx':
        raise ValueError('only assisted_full_tx captures are supported')
    status = text(data['status'])
    if status not in ('ok', 'error'):
        raise ValueError('invalid source status')
    bits = real_vector(data['tx_bits'], 'tx_bits')
    if not np.isin(bits, [0, 1]).all():
        raise ValueError('tx_bits must be binary')
    sps = scalar(data, 'sps')
    if sps != int(sps) or sps < 2 or sps % 2:
        raise ValueError('sps must be an even integer >= 2')
    sps = int(sps)
    bit_rate = scalar(data, 'bit_rate')
    tx_rate = scalar(data, 'tx_sample_rate')
    if bit_rate <= 0 or tx_rate <= 0 or not np.isclose(tx_rate, sps*bit_rate, rtol=1e-10):
        raise ValueError('inconsistent bit/sample rates')
    raw = real_vector(data['rx_raw'], 'rx_raw', allow_empty=True)
    tx = real_vector(data['tx_samples'], 'tx_samples', allow_empty=True)
    # Preserve early source failures as unavailable, rather than inventing samples.
    if len(raw):
        rx_rate = scalar(data, 'rx_sample_rate')
        if rx_rate != tx_rate:
            raise ValueError('unequal sample rates: MATLAB-equivalent resampling is not implemented')
    if len(tx):
        signed = 2*bits-1
        expected = np.repeat(np.column_stack([signed, -signed]).reshape(-1), sps//2)
        if not np.array_equal(tx, expected):
            raise ValueError('tx_samples do not match the declared Manchester bits/sps')
    if status == 'ok':
        original = real_vector(data['rx_aligned'], 'rx_aligned')
        if len(original) != len(bits)*sps or not len(raw) or not len(tx):
            raise ValueError('incomplete successful source capture')
    return meta, bits, tx, raw, sps


def read_archive(source):
    """Validate names and schema before creating any output. Never extract paths."""
    records = []
    ids, names, sessions, rates = set(), set(), {}, set()
    with ZipFile(source) as archive:
        total = 0
        for entry in archive.infolist():
            name = entry.filename
            path = PurePosixPath(name)
            if ('\\' in name or ':' in name or path.is_absolute()
                    or '..' in path.parts or not path.parts
                    or stat.S_ISLNK(entry.external_attr >> 16)):
                raise ValueError(f'unsafe ZIP member: {name!r}')
            if name in names:
                raise ValueError(f'duplicate ZIP member: {name}')
            names.add(name)
            if entry.is_dir():
                continue
            total += entry.file_size
            if entry.file_size > MAX_MEMBER_BYTES or total > MAX_ARCHIVE_BYTES:
                raise ValueError('ZIP exceeds the offline tool size limits')
            if path.suffix.lower() != '.mat':
                continue
            content = archive.read(entry)
            try:
                data = {k: v for k, v in loadmat(BytesIO(content), simplify_cells=True).items()
                        if not k.startswith('__')}
                meta, bits, tx, raw, sps = validate_capture(data)
            except (ValueError, KeyError, TypeError, NotImplementedError, MatReadError, IndexError) as exc:
                raise ValueError(f'{name}: {exc}') from exc
            capture_id, session = meta['capture_id'], meta['session_id']
            # Reject aliases even on Linux so the same archive is safe on Windows.
            if capture_id.casefold() in ids:
                raise ValueError(f'duplicate capture_id: {capture_id}')
            ids.add(capture_id.casefold())
            if session in sessions and sessions[session] != meta['split']:
                raise ValueError(f'session crosses splits: {session}')
            sessions[session] = meta['split']
            rates.add((sps, scalar(data, 'bit_rate')))
            records.append(dict(data=data, meta=meta, bits=bits, tx=tx, raw=raw,
                                sps=sps, source_member=name, source_sha256=sha256(content)))
    if not records:
        raise ValueError('no capture .mat files found')
    if len(rates) != 1:
        raise ValueError('separate archives with different sps/bit rates')
    return sorted(records, key=lambda record: record['meta']['capture_id'])


def reprocess_record(record, threshold):
    start = time.perf_counter()
    data, meta = record['data'], record['meta']
    raw, tx, bits, sps = (record[key] for key in ('raw', 'tx', 'bits', 'sps'))
    peak = float(np.max(np.abs(raw))) if len(raw) else 0.
    info = dict(method=SYNC_METHOD, accepted=False, threshold=float(threshold),
                score=None, start_sample=None, lag_samples=None, polarity=None,
                candidate_count=max(0, len(raw)-len(tx)+1) if len(tx) else 0,
                reason='source_signal_unavailable')
    aligned = np.empty(0, dtype=np.float64)
    sync_start = time.perf_counter()
    if len(raw) and len(tx) and peak > 0:
        aligned, info = synchronize_samples(tx, raw/peak, threshold)
    elif len(raw) and peak == 0:
        info['reason'] = 'zero_rx_signal'
    sync_seconds = time.perf_counter()-sync_start
    status = 'ok' if info['accepted'] else 'error'
    errors = int(np.sum(manchester_bits(aligned, sps) != bits)) if info['accepted'] else None
    original_status = text(data['status'])
    original_errors = None
    if original_status == 'ok':
        original_errors = int(np.sum(manchester_bits(data['rx_aligned'], sps) != bits))
    source_record = {key: data[key] for key in (
        'status', 'stage', 'error_message', 'sync_mode', 'sync_method', 'sync_threshold',
        'sync_info', 'rx_aligned', 'sync_seconds', 'total_seconds') if key in data}
    derived = dict(data)
    derived.update(status=status, stage='synchronization',
                   error_message='' if info['accepted'] else f'reprocess: {info["reason"]}',
                   rx_aligned=aligned, sync_method=SYNC_METHOD, sync_threshold=float(threshold),
                   sync_info={key: np.nan if value is None else value for key, value in info.items()},
                   source_record=source_record, source_status=original_status,
                   source_member=record['source_member'], source_sha256=record['source_sha256'],
                   reprocess_sync_seconds=sync_seconds, reprocess_version=TOOL_VERSION,
                   timing_semantics='Original capture timing fields are unchanged; '
                                    'reprocess timing excludes file IO and hardware.')
    derived['reprocess_seconds'] = time.perf_counter()-start
    row = dict(capture_id=meta['capture_id'], session_id=meta['session_id'],
               condition_id=meta['condition_id'], split=meta['split'],
               source_member=record['source_member'], source_sha256=record['source_sha256'],
               source_status=original_status, source_stage=text(data.get('stage', 'unknown')),
               source_error_message=text(data.get('error_message', '')),
               source_bit_errors=original_errors, status=status, sync_method=SYNC_METHOD,
               sync_threshold=float(threshold), score=info['score'],
               start_sample=info['start_sample'], lag_samples=info['lag_samples'],
               polarity=info['polarity'], candidate_count=info['candidate_count'],
               reason=info['reason'], bits=len(bits), bits_evaluated=len(bits) if info['accepted'] else 0,
               bit_errors=errors, ber=errors/len(bits) if info['accepted'] else None,
               raw_samples=len(raw), raw_min=float(raw.min()) if len(raw) else None,
               raw_max=float(raw.max()) if len(raw) else None,
               adc_rail_samples=int(np.sum((raw <= -127) | (raw >= 127))),
               raw_sha256=vector_hash(raw) if len(raw) else '', payload_sha256=vector_hash(bits),
               reprocess_seconds=derived['reprocess_seconds'], reprocess_sync_seconds=sync_seconds)
    return derived, row


def duplicate_groups(rows, key):
    groups = defaultdict(list)
    for row in rows:
        if row[key]:
            groups[row[key]].append(row['capture_id'])
    return [ids for ids in groups.values() if len(ids) > 1]


def summarize(rows):
    accepted = [row for row in rows if row['status'] == 'ok']
    count = sum(row['bits_evaluated'] for row in accepted)
    errors = sum(row['bit_errors'] for row in accepted)
    scores = [row['score'] for row in rows if row['score'] is not None]
    available_raw = [row for row in rows if row['raw_samples']]
    source_bits = sum(r['bits'] for r in rows if r['source_status'] == 'ok')
    source_errors = sum(r['source_bit_errors'] for r in rows if r['source_status'] == 'ok')
    return dict(attempts=len(rows), source_status_counts=dict(Counter(r['source_status'] for r in rows)),
                source_bits_evaluated=source_bits, source_bit_errors=source_errors,
                source_ber=source_errors/source_bits if source_bits else None,
                accepted=len(accepted), rejected=len(rows)-len(accepted),
                recovered_capture_ids=[r['capture_id'] for r in accepted if r['source_status'] != 'ok'],
                newly_rejected_capture_ids=[r['capture_id'] for r in rows
                                            if r['source_status'] == 'ok' and r['status'] != 'ok'],
                bits_evaluated=count, bit_errors=errors, ber=errors/count if count else None,
                fer_given_alignment=sum(r['bit_errors'] > 0 for r in accepted)/len(accepted)
                                    if accepted else None,
                exact_frame_delivery=sum(r['bit_errors'] == 0 for r in accepted)/len(rows),
                score_min=min(scores) if scores else None, score_max=max(scores) if scores else None,
                raw_min=min(r['raw_min'] for r in available_raw) if available_raw else None,
                raw_max=max(r['raw_max'] for r in available_raw) if available_raw else None,
                adc_rail_samples=sum(r['adc_rail_samples'] for r in rows),
                duplicate_raw_groups=duplicate_groups(rows, 'raw_sha256'),
                duplicate_payload_groups=duplicate_groups(rows, 'payload_sha256'),
                sessions=dict(Counter(r['session_id'] for r in rows)),
                splits=dict(Counter(r['split'] for r in rows)))


def implementation_info():
    root = Path(__file__).resolve().parent
    try:
        commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                         text=True, stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'],
                                            text=True, stderr=subprocess.DEVNULL).strip())
    except (OSError, subprocess.CalledProcessError):
        commit, dirty = None, None
    return dict(tool_version=TOOL_VERSION, sync_method=SYNC_METHOD,
                python=platform.python_version(), numpy=np.__version__, scipy=scipy.__version__,
                git_commit=commit, git_dirty=dirty,
                code_sha256={name: sha256((root/name).read_bytes())
                             for name in ('capture_sync.py', 'reprocess_captures.py')})


def reprocess_archive(source, out, threshold=0.5, expected_sha256=None):
    source, out = Path(source).resolve(), Path(out).resolve()
    if not np.isfinite(threshold) or not 0 < threshold <= 1:
        raise ValueError('threshold must be finite and in (0, 1]')
    if out.exists():
        raise FileExistsError('output already exists; use a new directory')
    source_hash = file_sha256(source)
    if expected_sha256 is not None and source_hash != expected_sha256.lower():
        raise ValueError('source ZIP SHA-256 does not match the expected checksum')
    records = read_archive(source)
    out.mkdir(parents=True, exist_ok=False)
    captures = out/'captures'
    captures.mkdir()
    manifest = dict(state='running', started_at_utc=datetime.now(timezone.utc).isoformat(),
                    source_archive=str(source), source_archive_sha256=source_hash,
                    source_archive_bytes=source.stat().st_size, threshold=float(threshold),
                    implementation=implementation_info(), resampling='not_needed_equal_rates_only',
                    normalization='raw / max(abs(raw)) before synchronization',
                    scope='assisted_full_tx; one output per original attempt; no BER-based selection',
                    timing='Original timing fields describe original attempts, not the new pipeline.',
                    limits=dict(max_member_bytes=MAX_MEMBER_BYTES, max_archive_bytes=MAX_ARCHIVE_BYTES),
                    outputs=[])
    manifest_path = out/'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    rows = []
    try:
        for record in records:
            derived, row = reprocess_record(record, threshold)
            derived['source_archive_sha256'] = source_hash
            target = captures/f'{row["capture_id"]}.mat'
            with target.open('xb') as stream:
                savemat(stream, derived, do_compression=True, long_field_names=True, oned_as='row')
            row['derived_sha256'] = file_sha256(target)
            rows.append(row)
            manifest['outputs'].append(dict(capture_id=row['capture_id'],
                                             file=target.relative_to(out).as_posix(),
                                             source_member=row['source_member'],
                                             source_sha256=row['source_sha256'],
                                             derived_sha256=row['derived_sha256']))
        if file_sha256(source) != source_hash:
            raise ValueError('source ZIP changed during reprocessing')
        summary = summarize(rows)
        (out/'summary.json').write_text(json.dumps(summary, indent=2, allow_nan=False)+'\n',
                                       encoding='utf-8')
        with (out/'frames.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        manifest['state'] = 'complete'
    except Exception as exc:
        manifest.update(state='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        manifest['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
        manifest_path.write_text(json.dumps(manifest, indent=2, allow_nan=False)+'\n', encoding='utf-8')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Original capture ZIP (never modified)')
    parser.add_argument('--out', type=Path, required=True, help='New output directory')
    parser.add_argument('--threshold', type=float, default=0.5, help='Exploratory Pearson threshold')
    parser.add_argument('--expected-sha256', help='Optional pinned source ZIP checksum')
    args = parser.parse_args()
    try:
        summary = reprocess_archive(args.source, args.out, args.threshold, args.expected_sha256)
    except (ValueError, OSError, BadZipFile) as exc:
        parser.exit(1, f'Error: {exc}\n')
    print(json.dumps(summary, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
