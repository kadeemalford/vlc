"""Export compact audited summaries/plots, not raw captures or noise replicas."""
import argparse
import json
from pathlib import Path, PurePosixPath

from awgn_sweep import write_json
from reprocess_captures import file_sha256


def export_results(source, out):
    source, out = Path(source).resolve(), Path(out).resolve()
    manifest_path = source/'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('state') != 'complete' or not manifest.get('outputs_sha256'):
        raise ValueError('only complete audited experiment runs can be exported')
    for name, digest in manifest['outputs_sha256'].items():
        relative = PurePosixPath(name)
        path = source/relative
        if (relative.is_absolute() or '..' in relative.parts or '\\' in name or ':' in name
                or path.is_symlink() or not path.resolve().is_relative_to(source)):
            raise ValueError('unsafe experiment artifact path')
        if file_sha256(path) != digest:
            raise ValueError(f'modified experiment artifact: {name}')
    selected = [name for name in ('summary.json', 'curves.csv', 'ber.svg', 'fer.svg', 'availability.svg')
                if name in manifest['outputs_sha256']]
    if 'summary.json' not in selected or 'curves.csv' not in selected:
        raise ValueError('run lacks required summary artifacts')
    out.mkdir(parents=True, exist_ok=False)
    for name in selected:
        with (out/name).open('xb') as stream:
            stream.write((source/name).read_bytes())
    provenance = dict(source_run=str(source), source_manifest_sha256=file_sha256(manifest_path),
                      original_manifest=manifest,
                      exported_sha256={name: file_sha256(out/name) for name in selected},
                      scope='Compact summary export only; frames, code snapshots and any weights remain in source run.')
    write_json(out/'provenance.json', provenance)
    return provenance


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    export_results(args.source, args.out)
