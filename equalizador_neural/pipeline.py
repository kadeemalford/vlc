"""Comparacao offline de detectores Manchester; nao usa TX nas features."""
import argparse
import csv
import json
import platform
import time
from pathlib import Path

import numpy as np
import scipy
from scipy.io import loadmat
import torch
from torch import nn


def load_captures(directory):
    captures = []
    ids, sessions = set(), {}
    for path in sorted(Path(directory).rglob('*.mat')):
        d = loadmat(path, squeeze_me=True)
        meta = json.loads(str(d['metadata_json']))
        for key in ('capture_id', 'session_id', 'condition_id', 'split'):
            if not isinstance(meta.get(key), str) or not meta[key]:
                raise ValueError(f'{path}: metadata {key} invalido')
        split, session = meta['split'], meta['session_id']
        if split not in ('train', 'val', 'test'):
            raise ValueError(f'{path}: split invalido')
        if meta['capture_id'] in ids:
            raise ValueError('capture_id duplicado')
        ids.add(meta['capture_id'])
        if session in sessions and sessions[session] != split:
            raise ValueError(f'Sessao {session} atravessa splits: vazamento')
        sessions[session] = split
        mode = str(d['sync_mode'])
        if mode != 'assisted_full_tx':
            raise ValueError(f'{path}: este prototipo exige assisted_full_tx')
        y = np.atleast_1d(d['tx_bits']).astype(float).reshape(-1)
        if not len(y) or not np.isin(y, [0, 1]).all():
            raise ValueError(f'{path}: bits invalidos')
        sps_float = float(d['sps'])
        sps = int(sps_float)
        if sps != sps_float or sps < 2 or sps % 2:
            raise ValueError(f'{path}: sps deve ser inteiro positivo par')
        bit_rate = float(d['bit_rate'])
        if not np.isfinite(bit_rate) or bit_rate <= 0:
            raise ValueError(f'{path}: bit_rate deve ser finito e positivo')
        status = str(d['status'])
        if status not in ('ok', 'error'):
            raise ValueError(f'{path}: status invalido')
        x = np.atleast_1d(d['rx_aligned']).astype(np.float32).reshape(-1)
        if status == 'ok' and (len(x) != len(y)*sps or not np.isfinite(x).all()):
            raise ValueError(f'{path}: RX alinhado invalido')
        captures.append(dict(meta=meta, y=y.astype(np.int64), x=x, sps=sps,
                             status=status, bit_rate=bit_rate,
                             stage=str(d.get('stage', 'unknown')),
                             total_seconds=float(d.get('total_seconds', np.nan))))
    if not captures:
        raise ValueError('Nenhuma captura .mat encontrada')
    if len({(c['sps'], c['bit_rate']) for c in captures}) != 1:
        raise ValueError('Separe campanhas com sps/taxa diferentes')
    return captures


def windows(x, sps, context):
    """Contexto simetrico em bits, padding zero apenas nas bordas do quadro."""
    n = len(x)//sps
    padded = np.pad(x, context*sps)
    view = np.lib.stride_tricks.sliding_window_view(padded, (2*context+1)*sps)
    return view[::sps][:n].copy().astype(np.float32)


def integrator(x, sps):
    halves = x.reshape(-1, sps)
    return (halves[:, :sps//2].sum(1) > halves[:, sps//2:].sum(1)).astype(int)


class Detector(nn.Module):
    def __init__(self, width):
        super().__init__()
        self.net = nn.Sequential(nn.Conv1d(1, 16, 3, padding=1), nn.ReLU(),
                                 nn.Conv1d(16, 16, 3, padding=1), nn.ReLU(),
                                 nn.Flatten(), nn.Linear(16*width, 1))

    def forward(self, x):
        return self.net(x[:, None, :]).squeeze(1)


def arrays(captures, context):
    good = [c for c in captures if c['status'] == 'ok']
    if not good:
        raise ValueError('Split sem capturas bem-sucedidas')
    return (np.concatenate([windows(c['x'], c['sps'], context) for c in good]),
            np.concatenate([c['y'] for c in good]))


def fit_ridge(x, y, alpha):
    # MMSE empirico regularizado de alvos bipolares, intercepto nao penalizado.
    z = np.column_stack([x, np.ones(len(x))]).astype(np.float64)
    penalty = np.eye(z.shape[1])*alpha
    penalty[-1, -1] = 0
    return np.linalg.solve(z.T @ z / len(z) + penalty, z.T @ (2*y-1) / len(z))


def ridge_bits(x, weights):
    return (x @ weights[:-1] + weights[-1] > 0).astype(int)


def neural_bits(model, x, batch_size):
    model.eval()
    with torch.no_grad():
        return np.concatenate([(model(torch.from_numpy(x[i:i+batch_size])) > 0).numpy()
                               for i in range(0, len(x), batch_size)]).astype(int)


def train(args):
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    captures = load_captures(args.data)
    train_c = [c for c in captures if c['meta']['split'] == 'train']
    val_c = [c for c in captures if c['meta']['split'] == 'val']
    x, y = arrays(train_c, args.context)
    vx, vy = arrays(val_c, args.context)
    if len(np.unique(y)) != 2:
        raise ValueError('Treino deve conter ambas as classes de bits')
    # Estatisticas somente do treino; uma escala global, igual para CNN e linear.
    mean, scale = float(x.mean()), max(float(x.std()), 1e-8)
    x, vx = (x-mean)/scale, (vx-mean)/scale
    candidates = []
    for alpha in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1.):
        weights = fit_ridge(x, y, alpha)
        candidates.append((float(np.mean(ridge_bits(vx, weights) != vy)), alpha, weights))
    ridge_ber, alpha, weights = min(candidates, key=lambda t: t[0])
    model = Detector(x.shape[1])
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    loss_fn = nn.BCEWithLogitsLoss()
    dataset = torch.utils.data.TensorDataset(torch.from_numpy(x), torch.from_numpy(y.astype(np.float32)))
    loader = torch.utils.data.DataLoader(dataset, batch_size=args.batch_size, shuffle=True)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False) # Nao sobrescrever experimento anterior.
    best, history = float('inf'), []
    for epoch in range(1, args.epochs+1):
        model.train()
        loss_sum = 0.
        for bx, by in loader:
            optimizer.zero_grad()
            loss = loss_fn(model(bx), by)
            loss.backward()
            optimizer.step()
            loss_sum += loss.item()*len(by)
        ber = float(np.mean(neural_bits(model, vx, args.batch_size) != vy))
        history.append(dict(epoch=epoch, train_loss=loss_sum/len(y), val_ber=ber))
        if ber < best:
            best = ber
            torch.save(model.state_dict(), out/'cnn.pt')
        print(f'epoch={epoch} loss={loss_sum/len(y):.5f} val_BER={ber:.6g}')
    np.savez(out/'linear.npz', weights=weights)
    config = dict(context=args.context, sps=captures[0]['sps'], bit_rate=captures[0]['bit_rate'],
                  width=x.shape[1], mean=mean, scale=scale, seed=args.seed,
                  epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
                  sync_mode='assisted_full_tx', ridge_alpha=alpha,
                  ridge_val_ber=ridge_ber, cnn_val_ber=best, history=history,
                  training_ids=[c['meta']['capture_id'] for c in train_c],
                  validation_ids=[c['meta']['capture_id'] for c in val_c],
                  training_sessions=sorted({c['meta']['session_id'] for c in train_c}),
                  validation_sessions=sorted({c['meta']['session_id'] for c in val_c}),
                  threads=args.threads,
                  versions=dict(python=platform.python_version(), numpy=np.__version__,
                                scipy=scipy.__version__, torch=torch.__version__))
    (out/'config.json').write_text(json.dumps(config, indent=2)+'\n')


def wilson(errors, count):
    if not count:
        return None
    z = 1.959963984540054
    p = errors/count
    center = (p+z*z/(2*count))/(1+z*z/count)
    radius = z*np.sqrt(p*(1-p)/count+z*z/(4*count*count))/(1+z*z/count)
    return [max(0., center-radius), min(1., center+radius)]


def summarize(rows):
    attempts = len(rows)
    good = [r for r in rows if r['status'] == 'ok']
    n = sum(r['bits'] for r in good)
    errors = sum(r['errors'] for r in good)
    frame_errors = sum(r['errors'] > 0 for r in good)
    failures = [r for r in rows if r['status'] != 'ok']
    return dict(attempts=attempts, aligned_frames=len(good), failed_attempts=attempts-len(good),
                failures_by_stage={stage: sum(r.get('stage', 'unknown') == stage for r in failures)
                                   for stage in sorted({r.get('stage', 'unknown') for r in failures})},
                bits_evaluated=n, bit_errors=errors, ber=errors/n if n else None,
                ber_wilson95_iid=wilson(errors, n),
                fer_given_alignment=frame_errors/len(good) if good else None,
                exact_frame_delivery=(len(good)-frame_errors)/attempts if attempts else None,
                detector_seconds=sum(r['detector_seconds'] for r in good))


def evaluate(args):
    run = Path(args.run)
    cfg = json.loads((run/'config.json').read_text())
    captures = [c for c in load_captures(args.data) if c['meta']['split'] == args.split]
    if not captures:
        raise ValueError('Split vazio')
    forbidden = set(cfg['training_sessions'] + cfg['validation_sessions'])
    if args.split == 'test' and any(c['meta']['session_id'] in forbidden for c in captures):
        raise ValueError('Teste compartilha sessao com treino/validacao do modelo')
    if any(c['sps'] != cfg['sps'] or c['bit_rate'] != cfg['bit_rate'] for c in captures):
        raise ValueError('Taxa/sps diferem do modelo')
    model = Detector(cfg['width'])
    model.load_state_dict(torch.load(run/'cnn.pt', map_location='cpu', weights_only=True))
    weights = np.load(run/'linear.npz')['weights']
    # Warmup fora da medicao; tempo abaixo inclui decisao, nao aquisicao/features.
    neural_bits(model, np.zeros((1, cfg['width']), np.float32), args.batch_size)
    rows = []
    for c in captures:
        x = None
        if c['status'] == 'ok':
            x = (windows(c['x'], c['sps'], cfg['context'])-cfg['mean'])/cfg['scale']
        for method in ('integrator', 'linear_ridge', 'cnn'):
            errors, elapsed = 0, 0.
            if x is not None:
                start = time.perf_counter()
                if method == 'integrator':
                    predicted = integrator(c['x'], c['sps'])
                elif method == 'linear_ridge':
                    predicted = ridge_bits(x, weights)
                else:
                    predicted = neural_bits(model, x, args.batch_size)
                elapsed = time.perf_counter()-start
                errors = int(np.sum(predicted != c['y']))
            rows.append(dict(capture_id=c['meta']['capture_id'], session_id=c['meta']['session_id'],
                             condition_id=c['meta']['condition_id'], method=method,
                             status=c['status'], stage=c['stage'], bits=len(c['y']), errors=errors,
                             detector_seconds=elapsed, capture_seconds=c['total_seconds']))
    results = {}
    for method in ('integrator', 'linear_ridge', 'cnn'):
        selected = [r for r in rows if r['method'] == method]
        results[method] = dict(overall=summarize(selected),
                              by_condition={cond: summarize([r for r in selected if r['condition_id'] == cond])
                                            for cond in sorted({r['condition_id'] for r in selected})},
                              by_session={sess: summarize([r for r in selected if r['session_id'] == sess])
                                          for sess in sorted({r['session_id'] for r in selected})})
    target = run/f'evaluation_{args.split}.json'
    if target.exists() or (run/f'frames_{args.split}.csv').exists():
        raise ValueError('Avaliacao ja existe; preserve resultados ou use outra pasta de run')
    target.write_text(json.dumps(results, indent=2, allow_nan=False)+'\n')
    with (run/f'frames_{args.split}.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(json.dumps({m: r['overall'] for m, r in results.items()}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--threads', type=int, default=1)
    sub = parser.add_subparsers(dest='command', required=True)
    t = sub.add_parser('train')
    t.add_argument('--data', required=True)
    t.add_argument('--out', required=True)
    t.add_argument('--context', type=int, default=2)
    t.add_argument('--epochs', type=int, default=20)
    t.add_argument('--lr', type=float, default=1e-3)
    t.add_argument('--seed', type=int, default=42)
    t.add_argument('--batch-size', type=int, default=256)
    e = sub.add_parser('evaluate')
    e.add_argument('--data', required=True)
    e.add_argument('--run', required=True)
    e.add_argument('--split', choices=['train', 'val', 'test'], default='test')
    e.add_argument('--batch-size', type=int, default=256)
    args = parser.parse_args()
    if args.threads < 1 or args.batch_size < 1:
        parser.error('threads/batch-size devem ser positivos')
    if args.command == 'train' and (args.context < 0 or args.epochs < 1 or args.lr <= 0):
        parser.error('context >= 0, epochs >= 1, lr > 0')
    torch.set_num_threads(args.threads)
    (train if args.command == 'train' else evaluate)(args)


if __name__ == '__main__':
    main()
