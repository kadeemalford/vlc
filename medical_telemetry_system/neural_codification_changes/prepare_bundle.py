"""Snapshot selected source files for review; never patch or execute the legacy system."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil

# Explicit allowlist. Never traverse node_modules, .git, .env, databases or patient data.
CATALOG = (
    ('modify', 'vlc-system-matlab/src/scripts/alarm-care-pro/real_time_mae_vlc.m'),
    ('modify', 'vlc-system-matlab/src/main/model/system/system1tx1rx/System1tx1rx.m'),
    ('modify', 'vlc-system-matlab/src/main/model/system/system1tx1rx/System1tx1rxResponse.m'),
    ('modify', 'vlc-system-matlab/src/main/model/logicanalizers/Mdo3012/Mdo3012Analyzer.m'),
    ('modify_if_used', 'vlc-system-matlab/src/main/view/alarm-care-pro/TestEopSystemViewMae.m'),
    ('modify_if_used', 'vlc-system-matlab/src/main/view/alarm-care-pro/TestEopSystemViewMaeNew.m'),
    ('contract_reference', 'vlc-system-matlab/src/scripts/alarm-care-pro/mae_frontend.m'),
    ('contract_reference', 'vlc-system-matlab/src/scripts/alarm-care-pro/mae_frame.m'),
    ('contract_reference', 'vlc-system-matlab/src/scripts/alarm-care-pro/mae_registry.m'),
    ('parser_reference', 'vlc-system-matlab/src/scripts/alarm-care-pro/mae_handlers.m'),
    ('sync_reference', 'vlc-system-matlab/src/main/model/utils/SignalUtils.m'),
    ('contract_reference', 'alarm-care-pro-backend/src/gateway_server.ts'),
    ('contract_reference', 'alarm-care-pro-backend/src/services/TcpGateway.ts'),
    ('contract_reference', 'alarm-care-pro-backend/src/services/SocketServer.ts'),
    ('contract_reference', 'alarm-care-pro-frontend/src/pages/Home.tsx'),
    ('contract_reference', 'alarm-care-pro-frontend/src/utils/monitorVariables.ts'),
    ('contract_reference', 'alarm-care-pro-frontend/src/contexts/AlarmsContext.tsx'),
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare(system_root, out):
    root, out = Path(system_root).resolve(), Path(out).resolve()
    sources = []
    for role, relative in CATALOG:
        path = root/relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError(f'Missing or unsafe source: {relative}')
        sources.append((role, relative, path, digest(path)))
    out.mkdir(parents=True, exist_ok=False)
    manifest = dict(format='neural_integration_review_v1', state='preparing',
                    created_at_utc=datetime.now(timezone.utc).isoformat(), files=[],
                    warning='Reference copies only. No integration applied. Never add reference/ to MATLAB path.')
    try:
        for role, relative, path, before in sources:
            snapshot = relative + '.reference'
            destination = out/snapshot
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            if digest(destination) != before or digest(path) != before:
                raise ValueError(f'Source changed while snapshotting: {relative}')
            manifest['files'].append(dict(role=role, source=relative, snapshot=snapshot,
                                          sha256=before, bytes=path.stat().st_size))
        manifest['state'] = 'complete'
    except Exception:
        manifest['state'] = 'failed'
        raise
    finally:
        (out/'source_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


def verify(reference, system_root=None):
    reference = Path(reference).resolve()
    manifest = json.loads((reference/'source_manifest.json').read_text(encoding='utf-8'))
    if manifest.get('format') != 'neural_integration_review_v1' or manifest.get('state') != 'complete':
        raise ValueError('Not a complete review bundle')
    expected = dict((source, role) for role, source in CATALOG)
    found = set()
    for record in manifest['files']:
        source, snapshot = record['source'], record['snapshot']
        if (source not in expected or source in found or record['role'] != expected[source]
                or snapshot != source+'.reference'):
            raise ValueError('Unexpected or duplicate manifest entry')
        found.add(source)
        path = reference/snapshot
        if path.is_symlink() or not path.resolve().is_relative_to(reference) or digest(path) != record['sha256']:
            raise ValueError(f'Changed or unsafe snapshot: {source}')
        if system_root is not None:
            root = Path(system_root).resolve()
            live = root/source
            if live.is_symlink() or not live.resolve().is_relative_to(root) or digest(live) != record['sha256']:
                raise ValueError(f'Legacy source differs from review baseline: {source}')
    if found != set(expected):
        raise ValueError('Incomplete source inventory')
    return dict(state='verified', files=len(found), live_sources_checked=system_root is not None,
                integration_applied=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    command = sub.add_parser('snapshot')
    command.add_argument('--system-root', default=str(Path(__file__).resolve().parent.parent))
    command.add_argument('--out', default=str(Path(__file__).resolve().parent/'reference'))
    command = sub.add_parser('verify')
    command.add_argument('--reference', default=str(Path(__file__).resolve().parent/'reference'))
    command.add_argument('--system-root', help='Optionally also compare the live imported sources')
    args = parser.parse_args()
    if args.command == 'snapshot':
        result = prepare(args.system_root, args.out)
        print(json.dumps(dict(state=result['state'], files=len(result['files'])), indent=2))
    else:
        print(json.dumps(verify(args.reference, args.system_root), indent=2))


if __name__ == '__main__':
    main()
