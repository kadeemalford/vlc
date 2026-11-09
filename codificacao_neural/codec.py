"""Experimental deterministic byte codec. NOT encryption or a secret-key system."""
from pathlib import Path
import hashlib

import numpy as np
import torch
from torch import nn


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def byte_bits(payload):
    return np.unpackbits(np.frombuffer(payload, dtype=np.uint8)).reshape(-1, 8).astype(np.float32)


class ByteAutoencoder(nn.Module):
    """8 -> 32 -> 16 hard bits -> 32 -> 8. Expands, rather than compresses."""
    def __init__(self):
        super().__init__()
        self.encoder = nn.Sequential(nn.Linear(8, 32), nn.Tanh(), nn.Linear(32, 16))
        self.decoder = nn.Sequential(nn.Linear(16, 32), nn.Tanh(), nn.Linear(32, 8))

    def latent(self, bits):
        soft = torch.sigmoid(self.encoder(bits * 2 - 1))
        hard = (soft >= .5).to(soft.dtype)
        return soft + (hard - soft).detach()  # hard forward, straight-through gradient

    def forward(self, bits):
        return self.decoder(self.latent(bits) * 2 - 1)


def encode(model, payload):
    with torch.no_grad():
        bits = (model.latent(torch.from_numpy(byte_bits(payload))).numpy() >= .5).astype(np.uint8)
    return np.packbits(bits.reshape(-1)).tobytes()


def decode(model, latent):
    if len(latent) % 2:
        raise ValueError('Latent byte length must be even')
    bits = np.unpackbits(np.frombuffer(latent, dtype=np.uint8)).reshape(-1, 16).astype(np.float32)
    with torch.no_grad():
        predicted = model.decoder(torch.from_numpy(bits) * 2 - 1).numpy() >= 0
    return np.packbits(predicted.reshape(-1)).tobytes()


def conformance(model):
    alphabet = bytes(range(256))
    latent = encode(model, alphabet)
    recovered = decode(model, latent)
    return dict(alphabet_bytes=256, byte_errors=sum(a != b for a, b in zip(alphabet, recovered)),
                unique_codewords=len({latent[i:i+2] for i in range(0, len(latent), 2)}),
                latent_bits_per_byte=16, security_claim=False)


def fit(seed=42, steps=3000):
    if seed < 0 or steps < 1:
        raise ValueError('Seed must be nonnegative; steps must be positive')
    torch.set_num_threads(1)
    torch.manual_seed(seed)
    model = ByteAutoencoder()
    inputs = torch.from_numpy(byte_bits(bytes(range(256))))
    optimizer = torch.optim.Adam(model.parameters(), lr=.01)
    loss_fn = nn.BCEWithLogitsLoss()
    for step in range(1, steps + 1):
        optimizer.zero_grad()
        loss = loss_fn(model(inputs), inputs)
        loss.backward()
        optimizer.step()
        if step % 100 == 0:
            result = conformance(model)
            if result['byte_errors'] == 0 and result['unique_codewords'] == 256:
                break
    model.eval()
    return model, dict(seed=seed, steps_run=step, loss=float(loss.detach()), **conformance(model))


def save_model(model, path):
    torch.save(dict(format='vlc_neural_byte_codec_v1', state_dict=model.state_dict()), path)


def load_model(path):
    checkpoint = torch.load(path, map_location='cpu', weights_only=True)
    if checkpoint.get('format') != 'vlc_neural_byte_codec_v1':
        raise ValueError('Unsupported codec format')
    model = ByteAutoencoder()
    model.load_state_dict(checkpoint['state_dict'])
    model.eval()
    result = conformance(model)
    if result['byte_errors'] or result['unique_codewords'] != 256:
        raise ValueError('Model failed exhaustive clean-alphabet conformance; do not transmit')
    return model
