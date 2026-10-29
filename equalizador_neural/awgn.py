"""Reproducible post-alignment AWGN, with an explicitly nonphysical power axis."""
import hashlib
import json

import numpy as np
from scipy.special import ndtr

from capture_sync import manchester_bits, real_vector


NOISE_VERSION = 'gaussian_iid_expected_variance_v1'


def add_awgn(samples, capture_id, source_sha256, ratio_db, seed=42, realization=0, stream=None):
    """Use expected Gaussian variance, without centering/scaling each noise draw.

    ratio_db=None returns an untouched clean copy. No clipping, quantization,
    re-normalization or synchronization is applied after noise injection.
    """
    x = real_vector(samples, 'samples')
    if not isinstance(seed, int) or isinstance(seed, bool) or seed < 0:
        raise ValueError('seed must be a nonnegative integer')
    if not isinstance(realization, int) or realization < 0:
        raise ValueError('realization must be a nonnegative integer')
    if not capture_id or not source_sha256:
        raise ValueError('capture identity and source checksum are required')
    if ratio_db is not None and (not np.isfinite(ratio_db) or not -100 <= ratio_db <= 100):
        raise ValueError('added-noise reference ratio must be finite and within [-100, 100] dB')
    power = float(np.mean((x-x.mean())**2))
    if power <= 0:
        raise ValueError('positive captured AC power is required')
    ratio_db = None if ratio_db is None else (0. if ratio_db == 0 else float(ratio_db))
    key = json.dumps([NOISE_VERSION, seed, capture_id, source_sha256,
                      None if ratio_db is None else ratio_db.hex(), realization, stream],
                     separators=(',', ':')).encode('utf-8')
    noise_seed = hashlib.sha256(key).hexdigest()[:32]
    sigma = 0. if ratio_db is None else float(np.sqrt(power*10**(-float(ratio_db)/10)))
    if sigma:
        rng = np.random.Generator(np.random.PCG64(int(noise_seed, 16)))
        noise = sigma*rng.standard_normal(len(x))
    else:
        noise = np.zeros_like(x)
    info = dict(version=NOISE_VERSION, noise_seed_hex=noise_seed, seed=seed, stream=stream,
                realization=realization, ratio_db=None if ratio_db is None else float(ratio_db),
                captured_ac_power=power, sigma=sigma, expected_noise_power=sigma**2,
                realized_noise_power=float(np.mean(noise**2)), noise_mean=float(noise.mean()))
    return x+noise, info


def integrator_error_probabilities(samples, bits, sps, sigma):
    """Exact conditional probabilities for fixed waveform + independent AWGN.

    TX labels are used for this analytical metric only, never detector features.
    Each bit's differential sum receives noise variance sps*sigma**2.
    """
    x, y = real_vector(samples, 'samples'), real_vector(bits, 'bits')
    if not np.isin(y, [0, 1]).all() or len(x) != len(y)*sps:
        raise ValueError('invalid bit labels or frame size')
    # Validate sps and retain the exact tie convention for zero added noise.
    detected = manchester_bits(x, sps)
    if not np.isfinite(sigma) or sigma < 0:
        raise ValueError('sigma must be finite and nonnegative')
    if sigma == 0:
        return (detected != y).astype(float)
    sps = int(sps)
    frame = x.reshape(-1, sps)
    margin = (2*y-1)*(frame[:, :sps//2].sum(1)-frame[:, sps//2:].sum(1))
    return ndtr(-margin/(sigma*np.sqrt(sps)))


def frame_error_probability(probabilities):
    p = np.asarray(probabilities, dtype=float)
    if p.ndim != 1 or not len(p) or not np.isfinite(p).all() or np.any((p < 0) | (p > 1)):
        raise ValueError('expected a nonempty vector of probabilities in [0, 1]')
    with np.errstate(divide='ignore'):
        return float(-np.expm1(np.log1p(-p).sum()))
