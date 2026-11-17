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
from monitor_capture import MllpFramer, compact_frame, parse_rates
from packets import pack_packet, unpack_packet, verify_source


class ObservationExpired(TimeoutError):
    pass


class LiveBridge:
    def __init__(self, model_path, expected_hash, audit_path, max_age=2.0):
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
        self.latest = None
        self.pending = None
        self.counter = 0
        self.invalid_version = 0
        self.last_invalid_reason = None
        self.counts = Counter()
        self._log('created', model_sha256=expected_hash, max_age_seconds=max_age,
                  sync_mode='assisted_full_tx', signal='pulse_rate',
                  raw_hl7_saved=False, application_bytes_to_monitor=0,
                  code_sha256={name: sha256(Path(__file__).parent/name) for name in
                               ('live_bridge.py', 'live_bridge_server.py', 'codec.py',
                                'packets.py', 'monitor_capture.py')})

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
                records = [r for r in parse_rates(message) if r['signal'] == 'pulse_rate']
            except ValueError:
                self.counts['malformed_messages'] += 1
                return
            if not records:
                # An HL7 message about another signal is not a missing/invalid PR
                # observation. It must neither cancel PR nor refresh its age.
                self.counts['messages_without_pr'] += 1
                return
            if len(records) != 1 or not records[0]['eligible']:
                self.counts['source_rejected'] += 1
                reason = (records[0]['reason'] if len(records) == 1
                          else 'ambiguous_duplicate_signal')
                self.counts['pr_rejected_' + reason] += 1
                self.last_invalid_reason = reason
                self.invalid_version += 1
                # Do not deliver a queued value after the selected signal becomes invalid.
                if self.latest is not None:
                    self.counts['queue_dropped'] += 1
                self.latest = None
                return
            if self.latest is not None:
                self.counts['queue_dropped'] += 1
            self.latest = (compact_frame(records[0]), received)
            self.counts['source_accepted'] += 1

    def next_json(self):
        with self.lock:
            if self.stop_event.is_set():
                raise RuntimeError('Listener stopped; restart explicitly')
            if self.pending is not None:
                raise ValueError('Finish or reject the in-flight attempt first')
            if self.latest is None:
                return '{}'
            source, received = self.latest
            self.latest = None
            if time.monotonic() - received > self.max_age:
                self.counts['stale_dropped'] += 1
                return '{}'
            self.counter += 1
            if self.counter > 0xffffffff:
                raise ValueError('Message ID exhausted; start a new session')
            packet = pack_packet(encode(self.model, source), source, self.identity,
                                 self.counter, 0, 1)
            bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8))
            self.pending = dict(message_id=self.counter, received=received,
                                invalid_version=self.invalid_version,
                                source_sha256=hashlib.sha256(source).hexdigest(),
                                tx_bits=bits)
            self.counts['attempted'] += 1
            self._log('packet_prepared', message_id=self.counter,
                      source_sha256=self.pending['source_sha256'], transmitted_bits=len(bits))
            return json.dumps(dict(message_id=self.counter, tx_bits=bits.tolist()))

    def reject(self, reason='phy_rejected'):
        with self.lock:
            if self.pending is not None:
                self.counts['phy_rejected'] += 1
                self._log('phy_rejected', message_id=self.pending['message_id'],
                          reason='phy_rejected')  # Never persist arbitrary instrument/HL7 text.
                self.pending = None

    def receive_json(self, aligned_json):
        """Integrate Manchester RX; TX is used only for post-decode BER evaluation."""
        with self.lock:
            if self.pending is None:
                raise ValueError('No in-flight attempt')
            pending, self.pending = self.pending, None
            result = dict(message_id=pending['message_id'], codec_ok=False,
                          gateway_write_ok=False, panel_delivery_confirmed=False)
            try:
                samples = np.asarray(json.loads(aligned_json), dtype=float).reshape(-1)
                if len(samples) != 3920 or not np.all(np.isfinite(samples)):
                    raise ValueError('Invalid aligned waveform')
                frames = samples.reshape(-1, 10)
                bits = (frames[:, :5].mean(1) > frames[:, 5:].mean(1)).astype(np.uint8)
                packet = unpack_packet(np.packbits(bits).tobytes(), self.identity)
                if (packet['message_id'] != pending['message_id'] or
                        packet['index'] != 0 or packet['total'] != 1 or packet['source_bytes'] != 10):
                    raise ValueError('Unexpected logical message')
                source = decode(self.model, packet['latent'])
                verify_source(packet, source)
                if not re.fullmatch(rb'!#MDPR[0-9]{4}', source) or int(source[6:]) == 0:
                    raise ValueError('Unexpected compact PR frame')
                result.update(codec_ok=True, source_sha256=hashlib.sha256(source).hexdigest(),
                              source_exact_match=hashlib.sha256(source).hexdigest() == pending['source_sha256'],
                              bit_errors=int(np.count_nonzero(bits != pending['tx_bits'])),
                              evaluated_bits=len(bits))
                self.counts['codec_ok'] += 1
                age = time.monotonic() - pending['received']
                result['age_at_gateway_write_seconds'] = age
                if pending['invalid_version'] != self.invalid_version:
                    self.counts['invalidated'] += 1
                    result['reason'] = 'source_invalidated_during_phy'
                    result['source_invalid_reason'] = self.last_invalid_reason
                elif age > self.max_age:
                    self.counts['stale_dropped'] += 1
                    result['reason'] = 'stale'
                else:
                    envelope = dict(source='monitor_message', payload={
                        'type': 'Monitor Measurements',
                        'variables': [{'name': 'Puls Oxim Puls Rate',
                                       'value': str(int(source[6:])), 'unit': '1/min'}],
                        'alarms': []})
                    self._send(envelope, pending['received'])
                    result['gateway_write_ok'] = True
                    self.counts['gateway_write_ok'] += 1
            except ObservationExpired:
                self.counts['stale_dropped'] += 1
                result['reason'] = 'stale_during_gateway_connection'
            except (ValueError, TypeError, OverflowError):
                self.counts['codec_rejected'] += 1
                result['reason'] = 'invalid_rx'
            except OSError:
                self.counts['gateway_failed'] += 1
                result['reason'] = 'gateway_failed_no_retry'
                if self.gateway is not None:
                    self.gateway.close()
                    self.gateway = None
            self._log('attempt_finished', **result)
            return json.dumps(result)

    def _send(self, envelope, received):
        if self.gateway is None:
            self.gateway = socket.create_connection(self.gateway_address, timeout=.5)
        if time.monotonic() - received > self.max_age:
            raise ObservationExpired('Observation expired during gateway connection')
        # No recv, callbacks, medical sockets or command forwarding.
        self.gateway.sendall((json.dumps(envelope) + '\n').encode('utf-8'))

    def stats_json(self):
        with self.lock:
            return json.dumps(dict(self.counts))

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
                          unfinished_attempt=self.pending is not None)
                self.audit.close()
