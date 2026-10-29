"""Offline counterpart of matlab/synchronize_capture_samples.m (no hardware)."""
import numpy as np


SYNC_METHOD = 'valid_window_pearson_v1'


def real_vector(value, name, allow_empty=False):
    array = np.asarray(value)
    if (array.dtype.kind not in 'biuf' or np.iscomplexobj(array)
            or array.ndim > 2 or (array.ndim == 2 and min(array.shape) > 1)):
        raise ValueError(f'{name}: expected a real numeric vector')
    array = array.astype(np.float64).reshape(-1)
    if not np.isfinite(array).all() or (not allow_empty and not len(array)):
        raise ValueError(f'{name}: expected finite samples')
    return array


def synchronize_samples(tx, rx, threshold=0.5):
    """Return a polarity-corrected complete window and MATLAB-compatible info.

    Position is 1-based, lag is 0-based. No BER/labels select the window.
    This function does not normalize amplitude or resample its inputs.
    """
    if not np.isfinite(threshold) or not 0 < threshold <= 1:
        raise ValueError('threshold must be finite and in (0, 1]')
    tx = real_vector(tx, 'tx')
    rx = real_vector(rx, 'rx', allow_empty=True)
    if len(tx) < 2:
        raise ValueError('tx must contain at least two samples')
    n = len(tx)
    info = dict(method=SYNC_METHOD, accepted=False, threshold=float(threshold),
                score=None, start_sample=None, lag_samples=None, polarity=None,
                candidate_count=max(0, len(rx)-n+1), reason='')
    empty = np.empty(0, dtype=np.float64)
    if len(rx) < n:
        info['reason'] = 'record_shorter_than_frame'
        return empty, info
    reference = tx-tx.mean()
    reference_energy = np.sum(reference**2)
    if reference_energy <= 0:
        raise ValueError('constant tx cannot be synchronized using Pearson correlation')
    centered = rx-rx.mean()
    cs = np.r_[0., np.cumsum(centered)]
    cs2 = np.r_[0., np.cumsum(centered**2)]
    sums = cs[n:]-cs[:-n]
    energy = np.maximum(0., cs2[n:]-cs2[:-n]-sums**2/n)
    # MATLAB eps(x) is the spacing at x, not machine epsilon multiplied by x.
    energy_floor = 64*np.spacing(max(1., np.sum(centered**2)))
    valid = energy > energy_floor
    if not valid.any():
        info['reason'] = 'no_nonconstant_window'
        return empty, info
    numerator = np.convolve(centered, reference[::-1], mode='valid')
    scores = np.zeros(len(energy))
    scores[valid] = numerator[valid]/np.sqrt(energy[valid]*reference_energy)
    scores = np.clip(scores, -1., 1.)
    start = int(np.argmax(np.abs(scores)))
    score = float(abs(scores[start]))
    polarity = -1 if scores[start] < 0 else 1
    info.update(score=score, start_sample=start+1, lag_samples=start, polarity=polarity)
    if score < threshold:
        info['reason'] = 'correlation_below_threshold'
        return empty, info
    info.update(accepted=True, reason='accepted')
    return rx[start:start+n]*polarity, info


def manchester_bits(samples, sps):
    """Differential half-bit integrator, shared convention with the MATLAB code."""
    samples = real_vector(samples, 'samples')
    if int(sps) != sps or sps < 2 or sps % 2 or len(samples) % sps:
        raise ValueError('samples must contain complete bits with even integer sps')
    sps = int(sps)
    bits = samples.reshape(-1, sps)
    return (bits[:, :sps//2].sum(1) > bits[:, sps//2:].sum(1)).astype(np.int64)
