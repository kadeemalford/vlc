"""Timing schema shared by the live bridge and offline report (seconds)."""
from contextlib import contextmanager
import time

SCHEMA = 'neural_latency_v1'
TX_METRICS = (
    'source_parse_seconds', 'queue_wait_seconds', 'receive_to_encode_seconds',
    'encoder_seconds', 'framing_seconds',
)
RX_METRICS = (
    'packet_ready_to_rx_seconds', 'rx_json_seconds', 'manchester_decode_seconds',
    'packet_validation_seconds', 'decoder_seconds', 'source_validation_seconds',
    'bit_evaluation_seconds', 'source_evaluation_seconds', 'neural_seconds', 'gateway_envelope_seconds',
    'gateway_connect_seconds', 'gateway_serialize_seconds', 'gateway_write_seconds',
    'pc_to_gateway_write_seconds', 'rx_processing_seconds', 'age_at_attempt_end_seconds',
)
SOURCE_METRICS = ('source_interval_seconds', 'eligible_interval_seconds', 'source_parse_seconds',
                  'source_dispatch_seconds')
DROP_METRICS = ('queue_residence_seconds', 'source_age_seconds')
MATLAB_METRICS = (
    'matlab_next_rpc_seconds', 'matlab_request_json_seconds', 'matlab_baseband_seconds',
    'matlab_upload_seconds', 'matlab_acquisition_seconds', 'matlab_sync_seconds',
    'matlab_rx_json_seconds', 'matlab_receive_rpc_seconds', 'matlab_cycle_seconds',
    'matlab_capture_save_seconds',
)


@contextmanager
def measure(metrics, name):
    """Record elapsed time even when the measured operation fails."""
    start = time.perf_counter()
    try:
        yield
    finally:
        metrics[name] = time.perf_counter() - start
