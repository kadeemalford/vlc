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
import sys
import threading
import time

import numpy as np
import torch

from codec import decode, encode, load_model, sha256
from monitor_capture import MllpFramer
from monitor_signals import (SIGNALS, VITAL_SIGNALS, compact_observation,
                             parse_compact, parse_observations)
from packets import pack_packet, unpack_packet, verify_source
from latency import RX_METRICS, SCHEMA, TX_METRICS, measure


class ObservationExpired(TimeoutError):
    pass


class LiveBridge:
    def __init__(self, model_path, expected_hash, audit_path, max_age=2.0, signals=('pulse_rate',)):
        if (not isinstance(signals, (list, tuple)) or not signals or
                len(set(signals)) != len(signals) or any(s not in VITAL_SIGNALS for s in signals)):
            raise ValueError('Select distinct supported monitor signals')
        self.signals = tuple(signals)
        self.units = self.signals
        if not re.fullmatch(r'[0-9a-f]{64}', expected_hash):
            raise ValueError('Explicit frozen model SHA-256 required')
        startup = {}
        with measure(startup, 'model_hash_seconds'):
            actual_hash = sha256(model_path)
        if actual_hash != expected_hash:
            raise ValueError('Frozen model hash mismatch')
        if not 0 < max_age <= 5:
            raise ValueError('Maximum observation age must be in (0, 5] seconds')
        with measure(startup, 'model_load_and_conformance_seconds'):
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
        self.started_monotonic = time.monotonic()
        self.last_observed = {}
        self.last_eligible = {}
        self.source_sequence = Counter()
        self.online_encode_calls = 0
        self.online_decode_calls = 0
        self.listener_started_at = None
        self._log('created', model_sha256=expected_hash, max_age_seconds=max_age,
                  sync_mode='assisted_full_tx', signals=self.signals,
                  timing_schema=SCHEMA, startup_timings=startup,
                  runtime=dict(python=sys.version.split()[0], torch=str(torch.__version__),
                               numpy=np.__version__, torch_cpu_threads=torch.get_num_threads(),
                               device='cpu'),
                  first_online_is_cold_start=False,
                  raw_hl7_saved=False, application_bytes_to_monitor=0,
                  code_sha256={name: sha256(Path(__file__).parent/name) for name in
                               ('live_bridge.py', 'live_bridge_server.py', 'codec.py',
                                 'packets.py', 'monitor_capture.py', 'monitor_signals.py', 'latency.py')})

    def _count(self, name, signal=None):
        self.counts[name] += 1
        if signal is not None:
            self.signal_counts[signal][name] += 1

    def _log(self, event, **fields):
        payload = dict(event=event, unix_time=time.time(), timing_schema=SCHEMA)
        payload.update(fields)
        self.audit.write(json.dumps(payload,
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
        self.listener_started_at = time.monotonic()
        self._log('listener_started', port=int(port))
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
                        received_at = time.monotonic()
                        try:
                            messages = framer.feed(chunk)
                        except ValueError:
                            with self.lock:
                                self.counts['framing_rejected'] += 1
                            break
                        for message in messages:
                            self.feed_message(message, received_at=received_at)
                    if framer.buffer:
                        with self.lock:
                            self.counts['truncated_connections'] += 1
        except OSError:
            if not self.stop_event.is_set():
                with self.lock:
                    self.counts['listener_failed'] += 1
                self.stop_event.set()

    def feed_message(self, message, received_at=None):
        """Shared parsing path; accepts complete HL7 envelopes only, never logs them."""
        received = time.monotonic() if received_at is None else received_at
        with self.lock:
            dispatch_seconds = time.monotonic()-received
            self.counts['messages'] += 1
            parse_timings = {}
            try:
                with measure(parse_timings, 'source_parse_seconds'):
                    records = parse_observations(message, self.signals)
            except ValueError:
                self.counts['malformed_messages'] += 1
                self._log('source_parse_failed', timings=parse_timings)
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
                eligible = len(rows) == 1 and rows[0]['eligible']
                self.source_sequence[signal] += 1
                source_info = dict(source_sequence=self.source_sequence[signal],
                                   source_parse_seconds=parse_timings['source_parse_seconds'])
                previous = self.last_observed.get(signal)
                interval = received-previous if previous is not None and received >= previous else None
                previous_eligible = self.last_eligible.get(signal)
                eligible_interval = (received-previous_eligible if eligible and previous_eligible is not None
                                     and received >= previous_eligible else None)
                self.last_observed[signal] = received
                if eligible:
                    self.last_eligible[signal] = received
                self._log('source_observed', signal=signal, source_sequence=source_info['source_sequence'],
                          eligible=eligible, reason=rows[0]['reason'] if len(rows) == 1
                          else 'ambiguous_duplicate_signal',
                          source_elapsed_seconds=received-self.started_monotonic,
                          timings=dict(source_interval_seconds=interval,
                                       eligible_interval_seconds=eligible_interval,
                                       source_dispatch_seconds=dispatch_seconds, **parse_timings))
                if len(rows) != 1 or not rows[0]['eligible']:
                    self._count('source_rejected', signal)
                    reason = rows[0]['reason'] if len(rows) == 1 else 'ambiguous_duplicate_signal'
                    self.counts[SIGNALS[signal]['abbreviation'].lower() + '_rejected_' + reason] += 1
                    self.signal_counts[signal]['rejected_' + reason] += 1
                    self.last_invalid_reason[signal] = reason
                    self.invalid_version[signal] += 1
                    if signal in self.latest:
                        self._count('queue_dropped', signal)
                        self._drop_queued(signal, 'source_invalidated')
                    continue
                if signal in self.latest:
                    self._count('queue_dropped', signal)
                    self._drop_queued(signal, 'queue_replaced')
                source_info['queue_entered'] = time.monotonic()
                self.latest[signal] = ({signal: compact_observation(rows[0])}, received, source_info)
                self._count('source_accepted', signal)

    def _drop_queued(self, signal, reason):
        _, received, info = self.latest.pop(signal)
        now = time.monotonic()
        self._log('source_dropped', signal=signal, source_sequence=info['source_sequence'],
                  reason=reason, timings=dict(queue_residence_seconds=now-info['queue_entered'],
                                              source_age_seconds=now-received))

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
                # At most three observations, one latest value per selected signal.
                for offset in range(len(self.units)):
                    index = (self.next_signal_index + offset) % len(self.units)
                    unit = self.units[index]
                    if unit not in self.latest:
                        continue
                    sources, received, info = self.latest[unit]
                    if time.monotonic() - received > self.max_age:
                        for signal in sources:
                            self._count('stale_dropped', signal)
                        self._drop_queued(unit, 'stale_before_encode')
                        continue
                    del self.latest[unit]
                    self.counter += 1
                    if self.counter > 0xffffffff:
                        raise ValueError('Message ID exhausted; start a new session')
                    self.active = dict(message_id=self.counter, sources=sources, received=received,
                                       versions={s: self.invalid_version[s] for s in sources},
                                       index=0, decoded={}, source_info=info)
                    self.next_signal_index = (index + 1) % len(self.units)
                    self.counts['logical_prepared'] += 1
                    break
            if self.active is None:
                return '{}'
            active = self.active
            index = active['index']
            total = len(active['sources'])
            signal, source = list(active['sources'].items())[index]
            info = active['source_info']
            timing = dict.fromkeys(TX_METRICS)
            timing.update(source_parse_seconds=info['source_parse_seconds'],
                          queue_wait_seconds=time.monotonic()-info['queue_entered'],
                          receive_to_encode_seconds=time.monotonic()-active['received'])
            first_encode = self.online_encode_calls == 0
            self.online_encode_calls += 1
            try:
                with measure(timing, 'encoder_seconds'):
                    latent = encode(self.model, source)
                with measure(timing, 'framing_seconds'):
                    packet = pack_packet(latent, source, self.identity, active['message_id'], index, total)
                    bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8))
            except Exception:
                self._count('preparation_failed', signal)
                self._log('packet_preparation_failed', message_id=active['message_id'], signal=signal,
                          source_sequence=info['source_sequence'], first_online_encode=first_encode,
                          timings=timing)
                self.active = None
                raise
            self.pending = dict(message_id=active['message_id'], signal=signal, received=active['received'],
                                 index=index, total=total,
                                 source_sha256=hashlib.sha256(source).hexdigest(),
                                 tx_bits=bits, timings=timing, first_online_encode=first_encode,
                                 ready_at=time.monotonic(), source_sequence=info['source_sequence'])
            self._count('attempted', signal)
            self._log('packet_prepared', message_id=active['message_id'], signal=signal,
                      fragment_index=index, fragment_total=total,
                      source_sequence=info['source_sequence'], first_online_encode=first_encode,
                      timings=timing, source_sha256=self.pending['source_sha256'], transmitted_bits=len(bits))
            return json.dumps(dict(message_id=active['message_id'], signal=signal,
                                   fragment_index=index, fragment_total=total, tx_bits=bits.tolist()))

    def reject(self, reason='phy_rejected'):
        with self.lock:
            if self.pending is not None:
                self._count('phy_rejected', self.pending['signal'])
                self._log('phy_rejected', message_id=self.pending['message_id'],
                          signal=self.pending['signal'],
                          source_sequence=self.pending['source_sequence'],
                          first_online_encode=self.pending['first_online_encode'],
                          timings=dict(self.pending['timings'],
                                       age_at_attempt_end_seconds=time.monotonic()-self.pending['received']),
                          reason='phy_rejected')  # Never persist arbitrary instrument/HL7 text.
                self.pending = None
                self.active = None

    def receive_json(self, aligned_json):
        """Integrate Manchester RX; TX is used only for post-decode BER evaluation."""
        rx_entered = time.monotonic()
        rx_timer = time.perf_counter()
        with self.lock:
            if self.pending is None:
                raise ValueError('No in-flight attempt')
            pending, self.pending = self.pending, None
            signal = pending['signal']
            active = self.active
            result = dict(message_id=pending['message_id'], signal=signal, codec_ok=False,
                          fragment_index=pending['index'], fragment_total=pending['total'],
                          message_complete=False,
                          gateway_write_ok=False, panel_delivery_confirmed=False,
                          source_sequence=pending['source_sequence'],
                          first_online_encode=pending['first_online_encode'], first_online_decode=None,
                          deadline_met_at_gateway_write=None, timing_schema=SCHEMA)
            timing = dict(pending['timings'], **dict.fromkeys(RX_METRICS))
            timing['packet_ready_to_rx_seconds'] = rx_entered-pending['ready_at']
            result['timings'] = timing
            try:
                with measure(timing, 'rx_json_seconds'):
                    samples = np.asarray(json.loads(aligned_json), dtype=float).reshape(-1)
                    if len(samples) != 3920 or not np.all(np.isfinite(samples)):
                        raise ValueError('Invalid aligned waveform')
                with measure(timing, 'manchester_decode_seconds'):
                    frames = samples.reshape(-1, 10)
                    bits = (frames[:, :5].mean(1) > frames[:, 5:].mean(1)).astype(np.uint8)
                    packet_bytes = np.packbits(bits).tobytes()
                with measure(timing, 'bit_evaluation_seconds'):
                    # Evaluator only: include corrupt packets, not just CRC successes.
                    result.update(bit_errors=int(np.count_nonzero(bits != pending['tx_bits'])),
                                  evaluated_bits=len(bits))
                with measure(timing, 'packet_validation_seconds'):
                    packet = unpack_packet(packet_bytes, self.identity)
                    if (packet['message_id'] != pending['message_id'] or
                            packet['index'] != pending['index'] or packet['total'] != pending['total']
                            or packet['source_bytes'] != 10):
                        raise ValueError('Unexpected logical message')
                result['first_online_decode'] = self.online_decode_calls == 0
                self.online_decode_calls += 1
                with measure(timing, 'decoder_seconds'):
                    source = decode(self.model, packet['latent'])
                timing['neural_seconds'] = timing['encoder_seconds'] + timing['decoder_seconds']
                with measure(timing, 'source_validation_seconds'):
                    verify_source(packet, source)
                    value = parse_compact(source, signal)
                with measure(timing, 'source_evaluation_seconds'):
                    result.update(codec_ok=True, source_sha256=hashlib.sha256(source).hexdigest(),
                                  source_exact_match=hashlib.sha256(source).hexdigest() == pending['source_sha256'])
                self._count('codec_ok', signal)
                age = time.monotonic() - pending['received']
                # Compatibility alias: this is PRE-send, not write completion.
                result['age_at_gateway_write_seconds'] = age
                result['age_before_gateway_seconds'] = age
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
                    result['message_complete'] = True
                    with measure(timing, 'gateway_envelope_seconds'):
                        envelope, cleared = self._envelope(active['decoded'])
                    self._send(envelope, pending['received'], timing)
                    self.delivered[signal] = (pending['received'], active['versions'][signal])
                    result['gateway_write_ok'] = True
                    result['cleared_signals'] = cleared
                    self._count('gateway_write_ok', signal)
                    completed = timing['pc_to_gateway_write_seconds']
                    if completed is not None:
                        result['deadline_met_at_gateway_write'] = completed <= self.max_age
                        if not result['deadline_met_at_gateway_write']:
                            self._count('deadline_missed_after_write', signal)
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
            self.active = None
            if timing['decoder_seconds'] is not None:
                timing['neural_seconds'] = timing['encoder_seconds'] + timing['decoder_seconds']
            timing['age_at_attempt_end_seconds'] = time.monotonic()-pending['received']
            timing['rx_processing_seconds'] = time.perf_counter()-rx_timer
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
            if other in observations:
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

    def _send(self, envelope, received, timings=None):
        timings = {} if timings is None else timings
        if self.gateway is None:
            with measure(timings, 'gateway_connect_seconds'):
                self.gateway = socket.create_connection(self.gateway_address, timeout=.5)
        else:
            timings['gateway_connect_seconds'] = 0.0  # Reused connection; no connect operation.
        with measure(timings, 'gateway_serialize_seconds'):
            wire = (json.dumps(envelope) + '\n').encode('utf-8')
        if time.monotonic() - received > self.max_age:
            raise ObservationExpired('Observation expired during gateway connection')
        # No recv, callbacks, medical sockets or command forwarding.
        with measure(timings, 'gateway_write_seconds'):
            self.gateway.sendall(wire)
            timings['pc_to_gateway_write_seconds'] = time.monotonic()-received

    def stats_json(self):
        with self.lock:
            return json.dumps(dict(self.counts, signals={s: dict(c) for s, c in self.signal_counts.items()}))

    def close(self):
        close_requested = time.monotonic()
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
                           listening_seconds=(close_requested-self.listener_started_at
                                              if self.listener_started_at is not None else None),
                           queued_at_close={s: info['source_sequence']
                                            for s, (_, _, info) in self.latest.items()},
                           unfinished_attempt=self.pending is not None or self.active is not None)
                self.audit.close()
