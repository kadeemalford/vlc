"""Opt-in research bridge. Import/construction never opens network connections.

MATLAB owns the PHY. Only validated RX can reach the legacy NDJSON gateway.
No medical commands, HL7 ACKs, raw HL7/PID logs, or TX fallback.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import socket
import threading
import time

import numpy as np

from codec import decode, encode, load_model, sha256
from monitor_capture import MllpFramer
from monitor_signals import (PRESSURE_SIGNALS, SIGNALS, compact_observation,
                             parse_compact, parse_observations)
from packets import pack_packet, unpack_packet, verify_source


class ObservationExpired(TimeoutError):
    pass


class LiveBridge:
    def __init__(self, model_path, expected_hash, audit_path, max_age=2.0, signals=('pulse_rate',)):
        if (not isinstance(signals, (list, tuple)) or not signals or
                len(set(signals)) != len(signals) or any(s not in SIGNALS for s in signals)):
            raise ValueError('Select distinct supported monitor signals')
        self.signals = tuple(signals)
        if any(s in self.signals for s in PRESSURE_SIGNALS) and not all(
                s in self.signals for s in PRESSURE_SIGNALS):
            raise ValueError('Select systolic and diastolic pressure together')
        self.units = tuple(s for s in self.signals if s not in PRESSURE_SIGNALS)
        if all(s in self.signals for s in PRESSURE_SIGNALS):
            self.units += ('blood_pressure',)
        if not re.fullmatch(r'[0-9a-f]{64}', expected_hash):
            raise ValueError('Explicit frozen model SHA-256 required')
        if sha256(model_path) != expected_hash:
            raise ValueError('Frozen model hash mismatch')
        if not 0 < max_age <= 5:
            raise ValueError('Maximum observation age must be in (0, 5] seconds')
        self.model = load_model(model_path)
        self.model_hash = expected_hash
        self.identity = bytes.fromhex(expected_hash)[:8]
        self.max_age = max_age
        self.audit_path = Path(audit_path)
        # Exclusive output: do not overwrite another run's audit trail.
        self.audit = self.audit_path.open('x', encoding='utf-8')
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.worker = None
        self.server = None
        self.gateway = None
        self.latest = {}
        self.next_signal_index = 0
        self.pending = None
        self.active = None
        self.counter = 0
        self.invalid_version = dict.fromkeys(self.signals, 0)
        self.last_invalid_reason = dict.fromkeys(self.signals)
        self.delivered = {}
        self.counts = Counter()
        self.signal_counts = {signal: Counter() for signal in self.signals}
        self._log('created', model_sha256=expected_hash, max_age_seconds=max_age,
                  sync_mode='assisted_full_tx', signals=self.signals,
                  raw_hl7_saved=False, application_bytes_to_monitor=0,
                  code_sha256={name: sha256(Path(__file__).parent/name) for name in
                               ('live_bridge.py', 'live_bridge_server.py', 'codec.py',
                                'packets.py', 'monitor_capture.py', 'monitor_signals.py')})

    def _count(self, name, signal=None):
        self.counts[name] += 1
        if signal is not None:
            self.signal_counts[signal][name] += 1

    def _log(self, event, **fields):
        self.audit.write(json.dumps(dict(event=event, unix_time=time.time(), **fields),
                                    allow_nan=False) + '\n')
        self.audit.flush()

    def start(self, host, port=2222, gateway_host='127.0.0.1', gateway_port=4455):
        """Explicit listener activation; gateway connects lazily on valid delivery."""
        if self.worker is not None or self.stop_event.is_set():
            raise ValueError('Bridge cannot be started twice')
        if gateway_host != '127.0.0.1':
            raise ValueError('Initial research gateway must be local')
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            server.bind((host, int(port)))
            server.listen(1)
            server.settimeout(.1)
        except BaseException:
            server.close()
            raise
        self.server = server
        self.gateway_address = (gateway_host, int(gateway_port))
        self.worker = threading.Thread(target=self._listen, daemon=True)
        self.worker.start()

    def _listen(self):
        try:
            while not self.stop_event.is_set():
                try:
                    connection, _ = self.server.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(.1)
                    framer = MllpFramer()
                    while not self.stop_event.is_set():
                        try:
                            chunk = connection.recv(65536)
                        except socket.timeout:
                            continue
                        except ConnectionError:
                            break
                        if not chunk:
                            break
                        try:
                            messages = framer.feed(chunk)
                        except ValueError:
                            with self.lock:
                                self.counts['framing_rejected'] += 1
                            break
                        for message in messages:
                            self.feed_message(message)
                    if framer.buffer:
                        with self.lock:
                            self.counts['truncated_connections'] += 1
        except OSError:
            if not self.stop_event.is_set():
                with self.lock:
                    self.counts['listener_failed'] += 1
                self.stop_event.set()

    def feed_message(self, message):
        """Shared parsing path; accepts complete HL7 envelopes only, never logs them."""
        received = time.monotonic()
        with self.lock:
            self.counts['messages'] += 1
            try:
                records = parse_observations(message, self.signals)
            except ValueError:
                self.counts['malformed_messages'] += 1
                return
            if not records:
                self.counts['messages_without_selected_signals'] += 1
            for signal in self.signals:
                rows = [r for r in records if r['signal'] == signal]
                if not rows:
                    self.signal_counts[signal]['absent_messages'] += 1
                    if signal == 'pulse_rate':
                        self.counts['messages_without_pr'] += 1
                    continue  # Absence is not invalidity and never refreshes age.
                if signal in PRESSURE_SIGNALS:
                    continue  # Process a complete SYS/DIA pair below, never half a cycle.
                if len(rows) != 1 or not rows[0]['eligible']:
                    self._count('source_rejected', signal)
                    reason = rows[0]['reason'] if len(rows) == 1 else 'ambiguous_duplicate_signal'
                    self.counts[SIGNALS[signal]['abbreviation'].lower() + '_rejected_' + reason] += 1
                    self.signal_counts[signal]['rejected_' + reason] += 1
                    self.last_invalid_reason[signal] = reason
                    self.invalid_version[signal] += 1
                    if signal in self.latest:
                        self._count('queue_dropped', signal)
                        del self.latest[signal]
                    continue
                if signal in self.latest:
                    self._count('queue_dropped', signal)
                self.latest[signal] = ({signal: compact_observation(rows[0])}, received)
                self._count('source_accepted', signal)
            if 'blood_pressure' in self.units:
                self._feed_pressure(records, received)

    def _feed_pressure(self, records, received):
        rows = {s: [r for r in records if r['signal'] == s] for s in PRESSURE_SIGNALS}
        if not any(rows.values()):
            return
        reason = None
        if any(len(rows[s]) != 1 for s in PRESSURE_SIGNALS):
            reason = 'incomplete_or_duplicate_pressure_pair'
        elif any(not rows[s][0]['eligible'] for s in PRESSURE_SIGNALS):
            reason = 'invalid_pressure_pair'
        else:
            times = [rows[s][0]['sample_time'] for s in PRESSURE_SIGNALS]
            if times[0] != times[1]:
                reason = 'inconsistent_pressure_time'
        if reason is not None:
            for signal in PRESSURE_SIGNALS:
                self.invalid_version[signal] += 1
                self.last_invalid_reason[signal] = reason
                self._count('source_rejected', signal)
                self.signal_counts[signal]['rejected_' + reason] += 1
                self.counts[SIGNALS[signal]['abbreviation'].lower() + '_rejected_' + reason] += 1
                if len(rows[signal]) == 1 and not rows[signal][0]['eligible']:
                    self.signal_counts[signal]['rejected_' + rows[signal][0]['reason']] += 1
            if 'blood_pressure' in self.latest:
                del self.latest['blood_pressure']
                for signal in PRESSURE_SIGNALS:
                    self._count('queue_dropped', signal)
            return
        if 'blood_pressure' in self.latest:
            for signal in PRESSURE_SIGNALS:
                self._count('queue_dropped', signal)
        sources = {s: compact_observation(rows[s][0]) for s in PRESSURE_SIGNALS}
        self.latest['blood_pressure'] = (sources, received)
        for signal in PRESSURE_SIGNALS:
            self._count('source_accepted', signal)

    def _active_invalid(self, active):
        return any(active['versions'][s] != self.invalid_version[s] for s in active['sources'])

    def _drop_active(self, reason):
        active, self.active = self.active, None
        for signal in active['sources']:
            self._count(reason, signal)
        self._log('logical_aborted', message_id=active['message_id'],
                  signals=list(active['sources']), reason=reason)

    def next_json(self):
        with self.lock:
            if self.stop_event.is_set():
                raise RuntimeError('Listener stopped; restart explicitly')
            if self.pending is not None:
                raise ValueError('Finish or reject the in-flight attempt first')
            if self.active is not None:
                if self._active_invalid(self.active):
                    self._drop_active('invalidated')
                elif time.monotonic() - self.active['received'] > self.max_age:
                    self._drop_active('stale_dropped')
            if self.active is None:
                # Up to four logical units: HR, SpO2, PR and a SYS/DIA pair.
                for offset in range(len(self.units)):
                    index = (self.next_signal_index + offset) % len(self.units)
                    unit = self.units[index]
                    if unit not in self.latest:
                        continue
                    sources, received = self.latest.pop(unit)
                    if time.monotonic() - received > self.max_age:
                        for signal in sources:
                            self._count('stale_dropped', signal)
                        continue
                    self.counter += 1
                    if self.counter > 0xffffffff:
                        raise ValueError('Message ID exhausted; start a new session')
                    self.active = dict(message_id=self.counter, sources=sources, received=received,
                                       versions={s: self.invalid_version[s] for s in sources},
                                       index=0, decoded={})
                    self.next_signal_index = (index + 1) % len(self.units)
                    self.counts['logical_prepared'] += 1
                    break
            if self.active is None:
                return '{}'
            active = self.active
            index = active['index']
            total = len(active['sources'])
            signal, source = list(active['sources'].items())[index]
            packet = pack_packet(encode(self.model, source), source, self.identity,
                                 active['message_id'], index, total)
            bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8))
            self.pending = dict(message_id=active['message_id'], signal=signal, received=active['received'],
                                index=index, total=total,
                                source_sha256=hashlib.sha256(source).hexdigest(),
                                tx_bits=bits)
            self._count('attempted', signal)
            self._log('packet_prepared', message_id=active['message_id'], signal=signal,
                      fragment_index=index, fragment_total=total,
                      source_sha256=self.pending['source_sha256'], transmitted_bits=len(bits))
            return json.dumps(dict(message_id=active['message_id'], signal=signal,
                                   fragment_index=index, fragment_total=total, tx_bits=bits.tolist()))

    def reject(self, reason='phy_rejected'):
        with self.lock:
            if self.pending is not None:
                self._count('phy_rejected', self.pending['signal'])
                self._log('phy_rejected', message_id=self.pending['message_id'],
                          signal=self.pending['signal'],
                          reason='phy_rejected')  # Never persist arbitrary instrument/HL7 text.
                self.pending = None
                self.active = None

    def receive_json(self, aligned_json):
        """Integrate Manchester RX; TX is used only for post-decode BER evaluation."""
        with self.lock:
            if self.pending is None:
                raise ValueError('No in-flight attempt')
            pending, self.pending = self.pending, None
            signal = pending['signal']
            active = self.active
            result = dict(message_id=pending['message_id'], signal=signal, codec_ok=False,
                          fragment_index=pending['index'], fragment_total=pending['total'],
                          message_complete=False,
                          gateway_write_ok=False, panel_delivery_confirmed=False)
            try:
                samples = np.asarray(json.loads(aligned_json), dtype=float).reshape(-1)
                if len(samples) != 3920 or not np.all(np.isfinite(samples)):
                    raise ValueError('Invalid aligned waveform')
                frames = samples.reshape(-1, 10)
                bits = (frames[:, :5].mean(1) > frames[:, 5:].mean(1)).astype(np.uint8)
                packet = unpack_packet(np.packbits(bits).tobytes(), self.identity)
                if (packet['message_id'] != pending['message_id'] or
                        packet['index'] != pending['index'] or packet['total'] != pending['total']
                        or packet['source_bytes'] != 10):
                    raise ValueError('Unexpected logical message')
                source = decode(self.model, packet['latent'])
                verify_source(packet, source)
                value = parse_compact(source, signal)
                result.update(codec_ok=True, source_sha256=hashlib.sha256(source).hexdigest(),
                              source_exact_match=hashlib.sha256(source).hexdigest() == pending['source_sha256'],
                              bit_errors=int(np.count_nonzero(bits != pending['tx_bits'])),
                              evaluated_bits=len(bits))
                self._count('codec_ok', signal)
                age = time.monotonic() - pending['received']
                result['age_at_gateway_write_seconds'] = age
                if self._active_invalid(active):
                    self._count('invalidated', signal)
                    result['reason'] = 'source_invalidated_during_phy'
                    result['source_invalid_reason'] = next(
                        self.last_invalid_reason[s] for s in active['sources']
                        if active['versions'][s] != self.invalid_version[s])
                elif age > self.max_age:
                    self._count('stale_dropped', signal)
                    result['reason'] = 'stale'
                else:
                    active['decoded'][signal] = value
                    active['index'] += 1
                    if active['index'] < len(active['sources']):
                        result['reason'] = 'awaiting_pressure_pair'
                    else:
                        result['message_complete'] = True
                        envelope, cleared = self._envelope(active['decoded'])
                        self._send(envelope, pending['received'])
                        for delivered_signal in active['sources']:
                            self.delivered[delivered_signal] = (
                                pending['received'], active['versions'][delivered_signal])
                            self.signal_counts[delivered_signal]['gateway_write_ok'] += 1
                        result['gateway_write_ok'] = True
                        result['cleared_signals'] = cleared
                        self._count('gateway_write_ok')
            except ObservationExpired:
                self._count('stale_dropped', signal)
                result['reason'] = 'stale_during_gateway_connection'
            except (ValueError, TypeError, OverflowError):
                self._count('codec_rejected', signal)
                result['reason'] = 'invalid_rx'
            except OSError:
                self._count('gateway_failed', signal)
                result['reason'] = 'gateway_failed_no_retry'
                if self.gateway is not None:
                    self.gateway.close()
                    self.gateway = None
            if result.get('reason') != 'awaiting_pressure_pair':
                self.active = None
            self._log('attempt_finished', **result)
            return json.dumps(result)

    def _envelope(self, observations):
        variables = [dict(name=SIGNALS[s]['panel_name'], value=str(value), unit=SIGNALS[s]['unit'])
                     for s, value in observations.items()]
        cleared = []
        now = time.monotonic()
        # Never resend cached numeric readings as fresh RX. Only append legacy
        # no-reading markers for other selected fields that are unknown/expired.
        for other in self.signals:
            if other in observations or other in PRESSURE_SIGNALS:
                continue
            delivered = self.delivered.get(other)
            if (delivered is None or now-delivered[0] > self.max_age or
                    delivered[1] != self.invalid_version[other]):
                other_spec = SIGNALS[other]
                variables.append(dict(name=other_spec['panel_name'], value='-?-',
                                      unit=other_spec['unit']))
                cleared.append(other)
        return dict(source='monitor_message', payload={
            'type': 'Monitor Measurements', 'variables': variables, 'alarms': []}), cleared

    def _send(self, envelope, received):
        if self.gateway is None:
            self.gateway = socket.create_connection(self.gateway_address, timeout=.5)
        if time.monotonic() - received > self.max_age:
            raise ObservationExpired('Observation expired during gateway connection')
        # No recv, callbacks, medical sockets or command forwarding.
        self.gateway.sendall((json.dumps(envelope) + '\n').encode('utf-8'))

    def stats_json(self):
        with self.lock:
            return json.dumps(dict(self.counts, signals={s: dict(c) for s, c in self.signal_counts.items()}))

    def close(self):
        self.stop_event.set()
        if self.worker is not None:
            self.worker.join(timeout=1)
        if self.server is not None:
            self.server.close()
        if self.gateway is not None:
            self.gateway.close()
        with self.lock:
            if not self.audit.closed:
                self._log('closed', counts=dict(self.counts),
                          signals={s: dict(c) for s, c in self.signal_counts.items()},
                           unfinished_attempt=self.pending is not None or self.active is not None)
                self.audit.close()
