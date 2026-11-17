"""Exact research monitor fields: ECG HR, SpO2, PR, and cuff pressure SYS/DIA.

Numeric eligibility is representation validation, not sensor/clinical validation.
"""
from collections import Counter
from decimal import Decimal, InvalidOperation
import re

SIGNALS = {
    'heart_rate': dict(code='147842', name='MDC_ECG_HEART_RATE', sub_id='1.7.4.147842',
                       abbreviation='HR', unit_code='MDC_DIM_BEAT_PER_MIN',
                       unit='1/min', panel_name='Ecg Heart Rate', maximum=9999),
    'oxygen_saturation': dict(code='150456', name='MDC_PULS_OXIM_SAT_O2', sub_id='1.3.1.150456',
                              abbreviation='SP', unit_code='MDC_DIM_PERCENT',
                              unit='%', panel_name='Puls Oxim Sat O2', maximum=100),
    'pulse_rate': dict(code='149530', name='MDC_PULS_OXIM_PULS_RATE', sub_id='1.3.1.149530',
                       abbreviation='PR', unit_code='MDC_DIM_BEAT_PER_MIN',
                       unit='1/min', panel_name='Puls Oxim Puls Rate', maximum=9999),
    'systolic_pressure': dict(code='150301', name='MDC_PRESS_CUFF_SYS', sub_id='1.1.9.150301',
                              abbreviation='BS', unit_code='MDC_DIM_MMHG',
                              unit='mmHg', panel_name='Systolic Pressure', maximum=9999),
    'diastolic_pressure': dict(code='150302', name='MDC_PRESS_CUFF_DIA', sub_id='1.1.9.150302',
                               abbreviation='BD', unit_code='MDC_DIM_MMHG',
                               unit='mmHg', panel_name='Diastolic Pressure', maximum=9999),
}
PRESSURE_SIGNALS = ('systolic_pressure', 'diastolic_pressure')
VITAL_SIGNALS = ('heart_rate', 'oxygen_saturation', 'pulse_rate')


def parse_observations(message, signals=None):
    selected = tuple(SIGNALS if signals is None else signals)
    if not selected or any(signal not in SIGNALS for signal in selected):
        raise ValueError('Unsupported monitor signals')
    lines = message.replace(b'\r\n', b'\r').replace(b'\n', b'\r').split(b'\r')
    header = lines[0].split(b'|')
    if len(header) < 2 or header[0] != b'MSH' or header[1] != b'^~\\&':
        raise ValueError('Unsupported HL7 header/separators')
    records = []
    for line in lines:
        fields = line.split(b'|')
        if len(fields) < 4 or fields[0] != b'OBX':
            continue
        identifier = fields[3].split(b'^')
        for signal in selected:
            spec = SIGNALS[signal]
            if len(identifier) < 2 or identifier[:2] != [spec['code'].encode(), spec['name'].encode()]:
                continue
            record = dict(signal=signal, abbreviation=spec['abbreviation'], value=None,
                          unit=spec['unit'], eligible=False, reason='missing_fields')
            if signal in PRESSURE_SIGNALS:
                # Used transiently only for pair consistency, never persisted by the bridge.
                record['sample_time'] = fields[14] if len(fields) > 14 else b''
            records.append(record)
            if len(fields) <= 11:
                continue
            if fields[2] != b'NM' or fields[4] != spec['sub_id'].encode():
                record['reason'] = 'unexpected_type_or_sub_id'
                continue
            units = fields[6].split(b'^')
            if len(units) < 2 or units[1] != spec['unit_code'].encode():
                record['reason'] = 'unexpected_units'
                continue
            if fields[11] not in (b'F', b'C'):
                record['reason'] = 'observation_not_final_or_corrected'
                continue
            try:
                value = Decimal(fields[5].decode('ascii'))
            except (UnicodeDecodeError, InvalidOperation):
                record['reason'] = 'non_numeric'
                continue
            # Zero/missing values remain excluded in this research mode.
            if not value.is_finite() or value < 1 or value > spec['maximum']:
                record['reason'] = 'outside_representation_range_or_missing'
                continue
            if value != value.to_integral_value():
                record['reason'] = 'non_integer_no_silent_rounding'
                continue
            record.update(value=int(value), eligible=True, reason='numeric_observation')
    counts = Counter(record['signal'] for record in records)
    for record in records:
        if counts[record['signal']] > 1:
            record.update(eligible=False, reason='ambiguous_duplicate_signal')
    return records


def compact_observation(record):
    spec = SIGNALS[record['signal']]
    value = record['value']
    if not record['eligible'] or not isinstance(value, int) or not 1 <= value <= spec['maximum']:
        raise ValueError('Invalid monitor observation')
    return f"!#MD{spec['abbreviation']}{value:04d}".encode('ascii')


def parse_compact(source, expected_signal):
    spec = SIGNALS[expected_signal]
    if not re.fullmatch(rb'!#MD' + spec['abbreviation'].encode() + rb'[0-9]{4}', source):
        raise ValueError('Unexpected compact monitor signal')
    value = int(source[6:])
    if not 1 <= value <= spec['maximum']:
        raise ValueError('Invalid compact monitor value')
    return value


def pressure_diagnostics(message):
    """Structural diagnostics only: no readings, device timestamps, PID or raw HL7."""
    records = parse_observations(message, PRESSURE_SIGNALS)
    fields_seen = []
    known_names = {spec['name'] for spec in SIGNALS.values()}
    for line in message.replace(b'\r\n', b'\r').replace(b'\n', b'\r').split(b'\r'):
        fields = line.split(b'|')
        if len(fields) < 4 or fields[0] != b'OBX':
            continue
        identity = fields[3].split(b'^')
        code = identity[0]
        name = identity[1] if len(identity) > 1 else b''
        sub_id = fields[4] if len(fields) > 4 else b''
        hints = [signal for signal in PRESSURE_SIGNALS
                 if code == SIGNALS[signal]['code'].encode()
                 or name == SIGNALS[signal]['name'].encode()
                 or sub_id == SIGNALS[signal]['sub_id'].encode()]
        if not hints and b'PRESS' not in name:
            continue
        units = fields[6].split(b'^') if len(fields) > 6 else []
        status = fields[11] if len(fields) > 11 else b''
        # Unknown free text is deliberately never echoed, even in an OBX field.
        fields_seen.append(dict(
            hints=hints,
            code=code.decode('ascii') if re.fullmatch(rb'[0-9]{1,9}', code) else 'other',
            name=name.decode('ascii') if name in {n.encode() for n in known_names} else 'other',
            sub_id=sub_id.decode('ascii') if re.fullmatch(rb'[0-9.]{1,32}', sub_id) else 'other',
            obx_type='NM' if fields[2] == b'NM' else 'other',
            unit='MDC_DIM_MMHG' if len(units) > 1 and units[1] == b'MDC_DIM_MMHG' else 'other',
            status=status.decode('ascii') if status in (b'F', b'C') else 'other',
            sample_time_present=bool(fields[14]) if len(fields) > 14 else False,
            exact_identity_matches=[s for s in PRESSURE_SIGNALS
                                    if identity[:2] == [SIGNALS[s]['code'].encode(),
                                                        SIGNALS[s]['name'].encode()]]))
    grouped = {s: [r for r in records if r['signal'] == s] for s in PRESSURE_SIGNALS}
    same_time = None
    if all(len(grouped[s]) == 1 for s in PRESSURE_SIGNALS):
        same_time = grouped[PRESSURE_SIGNALS[0]][0]['sample_time'] == grouped[PRESSURE_SIGNALS[1]][0]['sample_time']
    return dict(
        pressure_fields=fields_seen,
        recognized_counts={s: len(rows) for s, rows in grouped.items()},
        eligibility={s: [dict(eligible=r['eligible'], reason=r['reason']) for r in rows]
                     for s, rows in grouped.items()},
        sample_times_equal=same_time)
