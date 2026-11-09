"""Offline training, serializable TX packets and RX reconstruction. No instrument access."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
from scipy.io import loadmat, savemat
import torch

from codec import encode, decode, fit, load_model, save_model, sha256
from packets import MAX_SOURCE_BYTES, pack_packet, unpack_packet, verify_source


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def new_output(path):
    out = Path(path)
    out.mkdir(parents=True, exist_ok=False)
    return out


def train(out, seed=42, steps=3000):
    model, result = fit(seed, steps)
    out = new_output(out)
    save_model(model, out/'model.pt')
    for name in ('codec.py', 'packets.py', 'workflow.py'):
        shutil.copyfile(Path(__file__).parent/name, out/name)
    result.update(state='conformant' if result['byte_errors'] == 0 and result['unique_codewords'] == 256
                  else 'not_conformant', model_sha256=sha256(out/'model.pt'),
                  torch_version=torch.__version__,
                  warning='Alphabet fitting, not held-out clinical generalization or cryptography.',
                  code_sha256={n: sha256(out/n) for n in ('codec.py', 'packets.py', 'workflow.py')})
    write_json(out/'training.json', result)
    return result


def prepare(model_path, input_path, out, message_id=1):
    model = load_model(model_path)
    payload = Path(input_path).read_bytes()
    if not 1 <= len(payload) <= MAX_SOURCE_BYTES*65535:
        raise ValueError('Input must contain 1..1048560 bytes; one logical compact message per input')
    if not 0 <= message_id <= 0xffffffff:
        raise ValueError('Message ID out of range')
    digest = sha256(model_path)
    identity = bytes.fromhex(digest)[:8]
    parts = [payload[i:i+MAX_SOURCE_BYTES] for i in range(0, len(payload), MAX_SOURCE_BYTES)]
    out = new_output(out)
    records = []
    for index, source in enumerate(parts):
        packet = pack_packet(encode(model, source), source, identity, message_id, index, len(parts))
        name = f'packet_{index+1:04d}.mat'
        bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8)).astype(float)
        savemat(out/name, dict(tx_bits=bits, model_sha256=digest,
                message_id=message_id, fragment_index=index, fragment_total=len(parts),
                source_sha256=hashlib.sha256(source).hexdigest()), do_compression=True)
        records.append(dict(file=name, sha256=sha256(out/name), bits=len(bits)))
    manifest = dict(state='prepared', input_sha256=sha256(input_path), source_bytes=len(payload),
                    model_sha256=digest, message_id=message_id, packets=records,
                    transmitted_bits=sum(r['bits'] for r in records),
                    expansion=sum(r['bits'] for r in records)/(8*len(payload)),
                    warning='Neural coding only; no confidentiality or authentication guarantee.')
    write_json(out/'manifest.json', manifest)
    return manifest


def read_bits(path, ideal=False):
    data = loadmat(path, simplify_cells=True)
    if ideal:
        bits = np.asarray(data['tx_bits']).reshape(-1)
    else:
        # Never fall back to TX bits, even though assisted captures contain them.
        if data.get('status') != 'ok':
            raise ValueError('Physical capture was not accepted; BER/reconstruction unknown')
        value = float(data['sps'])
        if not np.isfinite(value) or value < 2 or value != int(value) or int(value) % 2:
            raise ValueError('Invalid Manchester samples per bit')
        sps = int(value)
        samples = np.asarray(data['rx_aligned'], dtype=float).reshape(-1)
        if not len(samples) or len(samples) % sps or not np.all(np.isfinite(samples)):
            raise ValueError('Invalid aligned RX waveform')
        frames = samples.reshape(-1, sps)
        bits = (frames[:, :sps//2].mean(1) > frames[:, sps//2:].mean(1)).astype(np.uint8)
    if not len(bits) or len(bits) % 8 or not np.all((bits == 0) | (bits == 1)):
        raise ValueError('Packet must contain whole bytes of binary values')
    return np.packbits(bits.astype(np.uint8)).tobytes()


def receive(model_path, paths, out, ideal=False, reference=None, bypass=False):
    model = load_model(model_path)
    identity = bytes.fromhex(sha256(model_path))[:8]
    rows, fragments, expected = [], {}, None
    for path in paths:
        row = dict(file=str(path), sha256=sha256(path), status='rejected')
        try:
            packet = unpack_packet(read_bits(path, ideal), identity)
            key = (packet['message_id'], packet['total'])
            if expected is not None and key != expected:
                raise ValueError('Mixed logical messages in a single receive run')
            source = packet['latent'] if bypass else decode(model, packet['latent'])
            if not bypass:
                verify_source(packet, source)
            if packet['index'] in fragments:
                raise ValueError('Duplicate fragment; do not silently select a replica')
            expected = key
            fragments[packet['index']] = source
            row.update(status='accepted', fragment_index=packet['index'])
        except (ValueError, KeyError) as exc:
            row['error'] = str(exc)
        rows.append(row)
    complete = (bool(rows) and all(r['status'] == 'accepted' for r in rows)
                and expected is not None and set(fragments) == set(range(expected[1])))
    out = new_output(out)
    result = dict(mode='ideal_tx_bits' if ideal else 'physical_rx_assisted_alignment',
                  decoder='bypassed' if bypass else 'neural', complete=complete,
                  attempts=len(rows), accepted=sum(r['status'] == 'accepted' for r in rows),
                  model_sha256=sha256(model_path), packets=rows,
                  warning='Bypass tests representation compatibility, not confidentiality. '
                          'CRC is not authentication. Failed/missing fragments are not zero-error messages.')
    if complete:
        payload = b''.join(fragments[i] for i in range(expected[1]))
        name = 'latent_bytes.bin' if bypass else 'reconstructed.bin'
        (out/name).write_bytes(payload)
        result.update(output_file=name, output_sha256=sha256(out/name), output_bytes=len(payload))
        if reference is not None:
            original = Path(reference).read_bytes()  # evaluation only, never used to reconstruct
            result.update(reference_sha256=sha256(reference), exact_match=original == payload,
                          byte_errors=sum(a != b for a, b in zip(original, payload))
                          + abs(len(original)-len(payload)))
    write_json(out/'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('train')
    p.add_argument('--out', required=True)
    p.add_argument('--seed', type=int, default=42)
    p.add_argument('--steps', type=int, default=3000)
    p = sub.add_parser('encode')
    p.add_argument('--model', required=True)
    p.add_argument('--input', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--message-id', type=int, default=1)
    p = sub.add_parser('decode')
    p.add_argument('--model', required=True)
    p.add_argument('--packets', nargs='+', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--reference')
    p.add_argument('--ideal', action='store_true', help='Explicit software-only TX bit loopback')
    p.add_argument('--bypass-decoder', action='store_true', help='Representation control, NOT a security test')
    args = parser.parse_args()
    if args.command == 'train':
        result = train(args.out, args.seed, args.steps)
    elif args.command == 'encode':
        result = prepare(args.model, args.input, args.out, args.message_id)
    else:
        result = receive(args.model, args.packets, args.out, args.ideal, args.reference, args.bypass_decoder)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
