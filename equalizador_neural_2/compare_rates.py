"""Export per-rate benchmark results without pooling bits or selecting a winning seed."""
import argparse
import csv
import json
from pathlib import Path

import shared  # noqa: F401
from reprocess_captures import file_sha256
from campaign import write_csv, write_json


def compare(runs, out):
    rows, sources, seen, signatures = [], [], set(), set()
    for run in runs:
        root = Path(run).resolve()
        manifest_path = root/'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        if manifest.get('state') != 'complete' or not manifest.get('outputs_sha256'):
            raise ValueError('Only complete new-proposal benchmark runs can be compared')
        for name, digest in manifest['outputs_sha256'].items():
            path = root/name
            if path.is_symlink() or not path.resolve().is_relative_to(root) or file_sha256(path) != digest:
                raise ValueError('Unsafe or changed benchmark artifact')
        key = (manifest['bit_rate'], manifest['seed'])
        if key in seen:
            raise ValueError('Duplicate rate/seed; do not silently pool multiple experiments')
        seen.add(key)
        signatures.add((manifest['context'], manifest['feedback'], manifest['epochs'],
                        manifest['protocol'], manifest['synthetic_only']))
        sources.append(dict(run=str(root), manifest_sha256=file_sha256(manifest_path)))
        with (root/'curves.csv').open(encoding='utf-8') as stream:
            for row in csv.DictReader(stream):
                row.update(seed=manifest['seed'], synthetic_only=manifest['synthetic_only'], source_run=str(root))
                rows.append(row)
    if not rows or len(signatures) != 1:
        raise ValueError('Provide runs with matching training/context/feedback protocols')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    write_csv(out/'curves.csv', rows)
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axis = plt.subplots(figsize=(8, 5))
    for seed in sorted({r['seed'] for r in rows}):
        for method in sorted({r['method'] for r in rows}):
            group = sorted([r for r in rows if r['method'] == method and r['seed'] == seed],
                           key=lambda r: float(r['bit_rate']))
            axis.plot([float(r['bit_rate'])/1e6 for r in group], [float(r['ber']) for r in group],
                      'o-', label=f'{method}, seed {seed}')
    axis.set_xlabel('Nominal bit rate (Mbit/s; not measured goodput)')
    axis.set_ylabel('BER conditional on accepted TX-assisted alignment')
    axis.set_yscale('symlog', linthresh=1/max(float(r['bits']) for r in rows))
    axis.grid(True, alpha=.3)
    axis.legend(fontsize='small')
    fig.tight_layout()
    fig.savefig(out/'ber.svg')
    fig.savefig(out/'ber.png', dpi=160)
    plt.close(fig)
    write_json(out/'provenance.json', dict(sources=sources,
               warning='No pooling, seed selection, throughput or causal streaming claim. '
                       'Zero observed errors are not proof of zero BER. Inspect failures and session results.',
               outputs_sha256={p.name: file_sha256(p) for p in out.iterdir() if p.is_file()}))
    return rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', nargs='+', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    compare(args.runs, args.out)
