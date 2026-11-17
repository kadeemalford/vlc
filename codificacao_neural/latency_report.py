"""Offline timing/delivery report. No models, instruments, listeners or gateway."""
import argparse
from collections import Counter
import csv
import json
import math
from pathlib import Path

import numpy as np

from latency import DROP_METRICS, MATLAB_METRICS, RX_METRICS, SCHEMA, SOURCE_METRICS, TX_METRICS
from monitor_signals import VITAL_SIGNALS


def read_events(path):
    """A crash-truncated last line is reported, never counted as a success."""
    raw = Path(path).read_bytes()
    lines = raw.splitlines()
    rows, warnings = [], []
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            row = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError('Non-finite JSON constant')))
            if not isinstance(row, dict):
                raise ValueError('Expected an event object')
        except (ValueError, UnicodeDecodeError):
            if index == len(lines)-1 and not raw.endswith(b'\n'):
                warnings.append(f'{Path(path).name}: truncated final event excluded')
                continue
            raise ValueError(f'Invalid event at {Path(path).name}:{index+1}') from None
        rows.append(row)
    return rows, warnings


def duration(row, name):
    value = row.get('timings', {}).get(name)
    if value is None or value == []:
        return None
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
        raise ValueError(f'Invalid duration: {name}')
    return float(value)


def distribution(rows, names):
    result = {}
    for name in names:
        values = [value * 1000 for row in rows if (value := duration(row, name)) is not None]
        result[name] = dict(unit='ms', n=len(values), missing=len(rows)-len(values),
                            mean_ms=float(np.mean(values)) if values else None,
                            median_ms=float(np.median(values)) if values else None,
                            p95_ms=float(np.percentile(values, 95, method='linear')) if values else None,
                            max_ms=max(values) if values else None)
    return result


def attempt_key(row):
    message, fragment = row.get('message_id'), row.get('fragment_index', 0)
    if (isinstance(message, bool) or not isinstance(message, int) or message < 1
            or isinstance(fragment, bool) or not isinstance(fragment, int) or fragment != 0):
        raise ValueError('Invalid active three-signal attempt identity')
    return message, fragment


def unique_attempts(rows, description):
    keys = [attempt_key(row) for row in rows]
    if len(keys) != len(set(keys)):
        raise ValueError(f'Duplicate {description}; do not silently count a retry twice')
    return set(keys)


def ratio(numerator, denominator):
    return numerator/denominator if denominator else None


def cadence(rows):
    eligible = [row for row in rows if row.get('eligible') is True]
    times = [row.get('source_elapsed_seconds') for row in eligible]
    if any(isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) for t in times):
        raise ValueError('Missing/invalid source time')
    if any(b < a for a, b in zip(times, times[1:])):
        raise ValueError('Non-monotonic source event times')
    return ratio(len(times)-1, times[-1]-times[0]) if len(times) >= 2 else None


def build_report(session):
    session = Path(session)
    rows, warnings = read_events(session/'events.jsonl')
    created = [r for r in rows if r.get('event') == 'created']
    if len(created) != 1 or created[0].get('timing_schema') != SCHEMA:
        raise ValueError('Session has no supported isolated timing instrumentation; old logs cannot recover it')
    if any(r.get('timing_schema') != SCHEMA for r in rows):
        raise ValueError('Mixed timing schemas in session')
    metadata = created[0]
    signals = metadata.get('signals')
    if not isinstance(signals, list) or not signals or any(s not in VITAL_SIGNALS for s in signals):
        raise ValueError('Unsupported session signals')
    closed_rows = [r for r in rows if r.get('event') == 'closed']
    if len(closed_rows) > 1:
        raise ValueError('Multiple session closures')
    closed = closed_rows[0] if closed_rows else {}
    if not closed:
        warnings.append('Python session has no closure record; counts may be incomplete')
    window = closed.get('listening_seconds')
    if window is not None and (not isinstance(window, (int, float)) or not math.isfinite(window) or window <= 0):
        raise ValueError('Invalid listening duration')
    matlab_path = session/'matlab_events.jsonl'
    matlab_rows = []
    if matlab_path.is_file():
        matlab_rows, matlab_warnings = read_events(matlab_path)
        warnings.extend(matlab_warnings)
        if any(r.get('timing_schema') != SCHEMA for r in matlab_rows):
            raise ValueError('MATLAB/Python timing schema mismatch')
        if not any(r.get('event') == 'matlab_session_finished' for r in matlab_rows):
            warnings.append('MATLAB has no normal-completion record')
    else:
        warnings.append('No MATLAB timing audit; PHY/RPC/save durations are unknown')

    result = dict(format='vlc_latency_report_v1', timing_schema=SCHEMA,
                  model_sha256=metadata.get('model_sha256'), runtime=metadata.get('runtime'),
                  startup_timings_seconds=metadata.get('startup_timings', {}),
                  listening_seconds=window, closed=bool(closed), warnings=warnings,
                  limits=[
                      'CPU encode/decode function wall times, including their byte/tensor conversion.',
                      'Model loading includes exhaustive conformance; first online inference is not a cold model.',
                      'PC-to-gateway ends at sendall return, not TCP acknowledgement or browser render.',
                      'Delivered latency is deadline-selected; inspect dropped/expired observations too.',
                      'Nested timing groups overlap: never sum RPC/PHY cycle and Python stages.',
                      'BER is observed on evaluable aligned frames, not the complete repeated AFG stream.',
                      'Goodput counts useful source bytes accepted for gateway writing, not panel acknowledgements.',
                      'No comparison with classical models and no clinical deadline certification.',
                  ], signals={})
    for signal in signals:
        events = [r for r in rows if r.get('signal') == signal]
        sources = [r for r in events if r.get('event') == 'source_observed']
        drops = [r for r in events if r.get('event') == 'source_dropped']
        prepared = [r for r in events if r.get('event') == 'packet_prepared']
        failures = [r for r in events if r.get('event') == 'packet_preparation_failed']
        finished = [r for r in events if r.get('event') == 'attempt_finished']
        rejected = [r for r in events if r.get('event') == 'phy_rejected']
        sent = [r for r in finished if r.get('gateway_write_ok') is True]
        not_sent = [r for r in finished if r.get('gateway_write_ok') is not True]
        matlab = [r for r in matlab_rows if r.get('event') == 'matlab_attempt' and r.get('signal') == signal]
        prep_keys = unique_attempts(prepared, 'prepared packets')
        finished_keys = unique_attempts(finished, 'RX results')
        rejected_keys = unique_attempts(rejected, 'PHY rejections')
        unique_attempts(matlab, 'MATLAB attempts')
        if finished_keys & rejected_keys or not (finished_keys | rejected_keys) <= prep_keys:
            raise ValueError('Unmatched/double-counted attempt outcomes')
        # MATLAB can fail after a Python result (e.g. response lost). Do not merge
        # the two statuses into a fabricated successful delivery.
        matlab_keys = {attempt_key(r) for r in matlab}
        if not matlab_keys <= prep_keys:
            raise ValueError('MATLAB attempt does not match a prepared packet')
        evaluable = [r for r in finished if 'evaluated_bits' in r and 'bit_errors' in r]
        for row in evaluable:
            n, errors = row['evaluated_bits'], row['bit_errors']
            if (type(n) is not int or type(errors) is not int or n != 392 or not 0 <= errors <= n):
                raise ValueError('Invalid observed bit-error counts')
        bits = sum(r['evaluated_bits'] for r in evaluable)
        errors = sum(r['bit_errors'] for r in evaluable)
        eligible = sum(r.get('eligible') is True for r in sources)
        stats = dict(source_observations=len(sources), source_eligible=eligible,
                     source_rejected=len(sources)-eligible, prepared_packets=len(prepared),
                     preparation_failed=len(failures), rx_results=len(finished), phy_rejected=len(rejected),
                     unfinished_prepared=len(prep_keys-finished_keys-rejected_keys),
                     codec_ok=sum(r.get('codec_ok') is True for r in finished),
                     source_exact_matches=sum(r.get('source_exact_match') is True for r in finished),
                     gateway_writes=len(sent), panel_delivery_automatically_confirmed=False,
                     write_completion_timed=sum(duration(r, 'pc_to_gateway_write_seconds') is not None for r in sent),
                     deadline_missed_after_write=sum(r.get('deadline_met_at_gateway_write') is False for r in sent),
                     observed_bit_errors=errors, evaluated_bits=bits,
                     ber_unknown_packets=len(prepared)-len(evaluable),
                     empirical_ber_on_aligned_frames=ratio(errors, bits),
                     eligible_to_gateway_fraction=ratio(len(sent), eligible),
                     prepared_to_gateway_fraction=ratio(len(sent), len(prepared)),
                     observed_eligible_cadence_hz=cadence(sources),
                     source_goodput_to_gateway_bps=ratio(80*len(sent), window),
                     prepared_wire_bits=sum(r.get('transmitted_bits', 0) for r in prepared),
                     nominal_expansion=4.9,
                     drop_reasons=dict(Counter(r.get('reason', 'unknown') for r in drops)),
                     not_sent_reasons=dict(Counter(r.get('reason', 'unknown') for r in not_sent)),
                     queued_at_close=signal in closed.get('queued_at_close', {}),
                     bridge_counts=closed.get('signals', {}).get(signal))
        groups = dict(
            source_input=distribution(sources, SOURCE_METRICS),
            source_drops=distribution(drops, DROP_METRICS),
            all_prepared=distribution(prepared, TX_METRICS),
            preparation_failures=distribution(failures, TX_METRICS),
            all_rx_results=distribution(finished, TX_METRICS+RX_METRICS),
            written_to_gateway=distribution(sent, RX_METRICS),
            not_written_to_gateway=distribution(not_sent, RX_METRICS),
            phy_rejected=distribution(rejected, TX_METRICS+('age_at_attempt_end_seconds',)),
            first_online_encoder=distribution([r for r in prepared if r.get('first_online_encode') is True],
                                              ('encoder_seconds',)),
            subsequent_encoder=distribution([r for r in prepared if r.get('first_online_encode') is False],
                                            ('encoder_seconds',)),
            first_online_decoder=distribution([r for r in finished if r.get('first_online_decode') is True],
                                              ('decoder_seconds',)),
            subsequent_decoder=distribution([r for r in finished if r.get('first_online_decode') is False],
                                            ('decoder_seconds',)),
            matlab_attempts=distribution(matlab, MATLAB_METRICS))
        result['signals'][signal] = dict(counts=stats, latency=groups)
    return result


def report(session, out):
    result = build_report(session)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    (out/'summary.json').write_text(json.dumps(result, indent=2, allow_nan=False)+'\n', encoding='utf-8')
    with (out/'latency.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=['signal', 'population', 'metric', 'unit',
                                                    'n', 'missing', 'mean_ms', 'median_ms', 'p95_ms', 'max_ms'])
        writer.writeheader()
        for signal, data in result['signals'].items():
            for population, metrics in data['latency'].items():
                for metric, statistics in metrics.items():
                    writer.writerow(dict(signal=signal, population=population, metric=metric, **statistics))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    result = report(args.session, args.out)
    print(json.dumps(dict(state='reported', output=args.out, warnings=result['warnings'],
                          signals={s: data['counts'] for s, data in result['signals'].items()}), indent=2))


if __name__ == '__main__':
    main()
