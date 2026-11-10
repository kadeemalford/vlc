"""Research-only monitor receiver: MLLP/TCP, rate observations only, no application writes.

No VISA, gateway, medical commands, raw HL7 persistence or patient identifiers.
The explicit --listen option opens a server; importing this module does not.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import socket
import time

RATES = {
    'heart_rate': ('147842', 'MDC_ECG_HEART_RATE', '1.7.4.147842', 'HR'),
    'pulse_rate': ('149530', 'MDC_PULS_OXIM_PULS_RATE', '1.3.1.149530', 'PR'),
}


class MllpFramer:
    """Bounded VT + message + FS CR stream, independent of TCP read boundaries."""
    def __init__(self, max_message_bytes=65536):
        self.buffer = bytearray()
        self.limit = max_message_bytes

    def feed(self, data):
        self.buffer.extend(data)
        messages = []
        while self.buffer:
            # Only line terminators are tolerated between complete envelopes.
            while self.buffer and self.buffer[0] in (10, 13):
                del self.buffer[0]
            if not self.buffer:
                break
            if self.buffer[0] != 11:
                raise ValueError('Expected MLLP VT start; unframed HL7 is not supported')
            end = self.buffer.find(b'\x1c\r', 1)
            if end < 0:
                if len(self.buffer) > self.limit + 3:
                    raise ValueError('MLLP message exceeds configured size limit')
                break
            if end-1 > self.limit or b'\x0b' in self.buffer[1:end]:
                raise ValueError('Oversized or nested MLLP envelope')
            messages.append(bytes(self.buffer[1:end]))
            del self.buffer[:end+2]
        return messages


def parse_rates(message):
    """Select exact OBX identifiers; never return PID/MSH contents or invalid raw values."""
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
        for signal, (code, name, sub_id, abbreviation) in RATES.items():
            if len(identifier) < 2 or identifier[:2] != [code.encode(), name.encode()]:
                continue
            record = dict(signal=signal, abbreviation=abbreviation, value_bpm=None,
                          eligible=False, reason='missing_fields')
            records.append(record)
            if len(fields) <= 11:
                continue
            if fields[2] != b'NM' or fields[4] != sub_id.encode():
                record['reason'] = 'unexpected_type_or_sub_id'
                continue
            units = fields[6].split(b'^')
            if len(units) < 2 or units[1] != b'MDC_DIM_BEAT_PER_MIN':
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
            if not value.is_finite() or value < 1 or value > 9999:
                record['reason'] = 'outside_representation_range_or_missing'
                continue
            if value != value.to_integral_value():
                record['reason'] = 'non_integer_no_silent_rounding'
                continue
            record.update(value_bpm=int(value), eligible=True, reason='numeric_observation')
    counts = Counter(r['signal'] for r in records)
    for record in records:
        if counts[record['signal']] > 1:
            record.update(eligible=False, reason='ambiguous_duplicate_signal')
    return records


def compact_frame(record):
    if not record['eligible'] or record['signal'] not in RATES:
        raise ValueError('No valid selected observation to export')
    abbreviation = RATES[record['signal']][3]
    return f"!#MD{abbreviation}{record['value_bpm']:04d}".encode('ascii')


class SessionWriter:
    def __init__(self, out, signal):
        if signal not in ('inspect', *RATES):
            raise ValueError('Select inspect, heart_rate or pulse_rate')
        self.out = Path(out)
        self.out.mkdir(parents=True, exist_ok=False)
        self.signal = signal
        self.messages = 0
        self.exported = []
        self.signals = Counter()
        self.rejections = Counter()

    def consume(self, message, elapsed_seconds):
        self.messages += 1
        rows = parse_rates(message)
        for record in rows:
            self.signals[record['signal']] += 1
            if not record['eligible']:
                self.rejections[record['reason']] += 1
            row = dict(message_index=self.messages, elapsed_seconds=elapsed_seconds, **record)
            if self.signal == record['signal'] and record['eligible']:
                payload = compact_frame(record)
                filename = f'monitor_{len(self.exported)+1:06d}.bin'
                (self.out/filename).write_bytes(payload)
                exported = dict(file=filename, message_index=self.messages,
                                signal=record['signal'], bytes=len(payload),
                                sha256=hashlib.sha256(payload).hexdigest())
                self.exported.append(exported)
                row['source_file'] = filename
            with (self.out/'observations.jsonl').open('a', encoding='utf-8') as stream:
                stream.write(json.dumps(row, allow_nan=False) + '\n')
            # Only canonical field labels and numeric values reach the console.
            print(f"{record['abbreviation']}: {record['value_bpm']} bpm; {record['reason']}", flush=True)


def capture(host, port, seconds, signal, out, max_samples=1):
    if not 1 <= port <= 65535 or not 0 < seconds <= 3600 or max_samples < 1:
        raise ValueError('Invalid port, duration or sample count')
    writer = SessionWriter(out, signal)
    started = time.monotonic()
    deadline = started + seconds
    manifest = dict(state='starting', host=host, port=port, signal=signal,
                    started_at_utc=datetime.now(timezone.utc).isoformat(),
                    duration_limit_seconds=seconds, max_samples=max_samples,
                    connections=0, bytes_received=0, truncated_connections=0,
                    malformed_messages=0, framing_errors=0,
                    raw_hl7_saved=False, application_bytes_sent=0,
                    code_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    warning='Research only. Numeric acceptance is not clinical/sensor validation. '
                            'No application ACK; monitor may require one. Inspect exports no frames.')

    def persist():
        manifest.update(messages=writer.messages, observed_signals=dict(writer.signals),
                        rejected_observations=dict(writer.rejections), exported=writer.exported,
                        elapsed_seconds=time.monotonic()-started)
        (writer.out/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')

    def done():
        return time.monotonic() >= deadline or (signal != 'inspect' and len(writer.exported) >= max_samples)

    persist()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            # No address reuse: do not mask another listener on the configured port.
            server.bind((host, port))
            server.listen(1)
            manifest['state'] = 'listening'
            persist()
            print(f'Listening on {host}:{port}; signal={signal}; no application writes', flush=True)
            while not done():
                server.settimeout(max(.001, min(.25, deadline-time.monotonic())))
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                manifest['connections'] += 1
                framer = MllpFramer()
                with connection:
                    print('Monitor connection accepted; remote address not logged', flush=True)
                    while not done():
                        connection.settimeout(max(.001, min(.25, deadline-time.monotonic())))
                        try:
                            chunk = connection.recv(65536)
                        except socket.timeout:
                            continue
                        except ConnectionError:
                            break
                        if not chunk:
                            break
                        manifest['bytes_received'] += len(chunk)
                        try:
                            messages = framer.feed(chunk)
                        except ValueError:
                            manifest['framing_errors'] += 1
                            # Close only this connection; do not guess boundaries or log its raw data.
                            break
                        for message in messages:
                            if done():
                                break
                            try:
                                writer.consume(message, time.monotonic()-started)
                            except ValueError:
                                manifest['malformed_messages'] += 1
                        persist()
                if framer.buffer:
                    manifest['truncated_connections'] += 1
        manifest['state'] = 'finished'
    except KeyboardInterrupt:
        manifest['state'] = 'interrupted'
    except Exception:
        manifest['state'] = 'failed'
        raise
    finally:
        persist()
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--listen', action='store_true', required=True,
                        help='Explicitly authorize a research-only TCP listener')
    parser.add_argument('--host', required=True, help='Local laboratory interface IPv4 address')
    parser.add_argument('--port', type=int, default=2222)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--signal', choices=('inspect', *RATES), default='inspect')
    parser.add_argument('--max-samples', type=int, default=1)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    print(json.dumps(capture(args.host, args.port, args.seconds, args.signal, args.out, args.max_samples), indent=2))


if __name__ == '__main__':
    main()
