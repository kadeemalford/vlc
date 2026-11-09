"""Public framing and CRC for accidental corruption, not authentication."""
import struct
import zlib

MAGIC = b'NC1'
HEADER = struct.Struct('>3s8sIHHHI')
MAX_SOURCE_BYTES = 16  # 61 bytes / 488 Manchester bits including framing


def pack_packet(latent, source, model_id, message_id, index, total):
    if not (1 <= len(source) <= MAX_SOURCE_BYTES and len(latent) == 2*len(source)):
        raise ValueError('Invalid source/latent length')
    if len(model_id) != 8 or not (0 <= message_id <= 0xffffffff and 0 <= index < total <= 65535):
        raise ValueError('Invalid packet identity')
    header = HEADER.pack(MAGIC, model_id, message_id, index, total, len(source), zlib.crc32(source))
    body = header + latent
    return body + struct.pack('>I', zlib.crc32(body))


def unpack_packet(packet, model_id):
    if len(packet) < HEADER.size + 6:
        raise ValueError('Truncated packet')
    body, checksum = packet[:-4], packet[-4:]
    if zlib.crc32(body) != struct.unpack('>I', checksum)[0]:
        raise ValueError('Packet CRC mismatch')
    magic, identity, message, index, total, size, source_crc = HEADER.unpack(body[:HEADER.size])
    if magic != MAGIC or identity != model_id:
        raise ValueError('Wrong protocol/model identity')
    if not (0 <= index < total <= 65535 and 1 <= size <= MAX_SOURCE_BYTES):
        raise ValueError('Invalid packet metadata')
    latent = body[HEADER.size:]
    if len(latent) != size*2:
        raise ValueError('Invalid latent length')
    return dict(message_id=message, index=index, total=total, source_bytes=size,
                source_crc=source_crc, latent=latent)


def verify_source(packet, source):
    if len(source) != packet['source_bytes'] or zlib.crc32(source) != packet['source_crc']:
        raise ValueError('Reconstructed source CRC mismatch; reject message')
