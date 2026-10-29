"""Load complete, checksummed reprocessing artifacts without importing torch."""
import json
from pathlib import Path, PurePosixPath

import numpy as np
from scipy.io import loadmat

from reprocess_captures import file_sha256, text, validate_capture, vector_hash


def load_audited_dataset(directory):
    root = Path(directory).resolve()
    manifest_path = root/'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('state') != 'complete' or not manifest.get('outputs'):
        raise ValueError('dataset manifest must describe a complete, nonempty reprocessing run')
    captures, ids, files, sessions, protocols = [], set(), set(), {}, set()
    for entry in manifest['outputs']:
        relative = PurePosixPath(entry['file'])
        if (relative.is_absolute() or '..' in relative.parts or '\\' in entry['file']
                or ':' in entry['file'] or relative.suffix != '.mat'):
            raise ValueError('unsafe dataset manifest path')
        path = root/relative
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError('dataset path escapes its root')
        if entry['file'] in files or file_sha256(path) != entry['derived_sha256']:
            raise ValueError('duplicate path or modified derived capture')
        files.add(entry['file'])
        data = loadmat(path, simplify_cells=True)
        meta, bits, tx, raw, sps = validate_capture(data)
        capture_id = meta['capture_id']
        if capture_id != entry['capture_id'] or capture_id.casefold() in ids:
            raise ValueError('duplicate or inconsistent capture identity')
        ids.add(capture_id.casefold())
        if (text(data['source_sha256']) != entry['source_sha256']
                or text(data['source_archive_sha256']) != manifest['source_archive_sha256']):
            raise ValueError('capture source lineage differs from manifest')
        session, split = meta['session_id'], meta['split']
        if session in sessions and sessions[session] != split:
            raise ValueError('session crosses splits')
        sessions[session] = split
        protocols.add((sps, float(data['bit_rate']), text(data['sync_mode']),
                       text(data['sync_method']), float(data['sync_threshold'])))
        captures.append(dict(meta=meta, y=bits.astype(np.int64),
                             x=np.asarray(data['rx_aligned'], dtype=float).reshape(-1),
                             raw=raw, tx=tx, sps=sps, bit_rate=float(data['bit_rate']),
                             status=text(data['status']), stage=text(data['stage']),
                             sync_method=text(data['sync_method']),
                             sync_threshold=float(data['sync_threshold']),
                             sync_score=float(data['sync_info']['score']) if 'score' in data['sync_info'] else None,
                             source_sha256=entry['source_sha256'],
                             derived_sha256=entry['derived_sha256'],
                             raw_sha256=vector_hash(raw) if len(raw) else None,
                             payload_sha256=vector_hash(bits)))
    if len(protocols) != 1:
        raise ValueError('mixed rates or synchronization protocols')
    actual_files = {p.relative_to(root).as_posix() for p in (root/'captures').rglob('*.mat')}
    if actual_files != files:
        raise ValueError('unlisted or missing capture files')
    return sorted(captures, key=lambda c: c['meta']['capture_id']), dict(
        root=str(root), manifest_sha256=file_sha256(manifest_path),
        source_archive_sha256=manifest['source_archive_sha256'],
        captures=[dict(capture_id=c['meta']['capture_id'],
                       derived_sha256=c['derived_sha256']) for c in captures])


def require_independent_splits(captures):
    """Basic leakage guard, not proof of scientific sample adequacy."""
    sessions = {split: {c['meta']['session_id'] for c in captures if c['meta']['split'] == split}
                for split in ('train', 'val', 'test')}
    if any(not group for group in sessions.values()):
        raise ValueError('independent train/val/test sessions required; do not split the one-session pilot')
    if any(sessions[a] & sessions[b] for a, b in [('train', 'val'), ('train', 'test'), ('val', 'test')]):
        raise ValueError('session leakage across train/val/test')
    for field in ('source_sha256', 'raw_sha256', 'payload_sha256'):
        seen = {}
        for capture in captures:
            digest, split = capture.get(field), capture['meta']['split']
            if digest and digest in seen and seen[digest] != split:
                raise ValueError(f'duplicated {field} crosses splits')
            if digest:
                seen[digest] = split
    return {key: sorted(value) for key, value in sessions.items()}


def load_campaign(directories):
    captures, sources, ids, protocols = [], [], set(), set()
    for directory in directories:
        batch, provenance = load_audited_dataset(directory)
        sources.append(provenance)
        for capture in batch:
            capture_id = capture['meta']['capture_id'].casefold()
            if capture_id in ids:
                raise ValueError('capture ID repeated across campaign directories')
            ids.add(capture_id)
            protocols.add((capture['sps'], capture['bit_rate'], capture['sync_method'], capture['sync_threshold']))
            captures.append(capture)
    if len(protocols) != 1:
        raise ValueError('campaign must use one rate and synchronization protocol')
    return captures, sources
