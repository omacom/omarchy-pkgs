#!/usr/bin/env python3
"""Read ROT1 status and explicitly query PFI or PCBI capabilities."""
import argparse
import ctypes
import fcntl
import json
import os
import struct

PCBI_SUCCESS = 0x7986ACBD
PCBI_ENUMERATE_SERVICES = 5
PCBI_ENUMERATE_VERSIONS = 7
PCBI_DEVICE_INFO = 4
PCBI_REPLY_CAPACITY = 1024
PCBI_DEVICE_INFO_CAPACITY = 4096


def query_capacity(command):
    if command == PCBI_DEVICE_INFO:
        return PCBI_DEVICE_INFO_CAPACITY
    if command in (PCBI_ENUMERATE_SERVICES, PCBI_ENUMERATE_VERSIONS):
        return PCBI_REPLY_CAPACITY
    raise ValueError('unsupported PCBI query')


def decode_device_info(body):
    if len(body) < 8 or not body[0]:
        raise ValueError('invalid PCBI device-info header')
    packages, offset = [], 8
    for _ in range(body[1]):
        if len(body) - offset < 36:
            raise ValueError('truncated PCBI package record')
        record = body[offset:offset + 36]
        custom_size = struct.unpack_from('<H', record, 34)[0]
        if (not any(record[:8]) or not record[32] or record[33] & 0xf0 or
                custom_size > 64 or custom_size > len(body) - offset - 36):
            raise ValueError('invalid PCBI package record')
        packages.append({'name_hex': record[:8].hex(),
                         'metadata_hex': record[8:32].hex(),
                         'type': record[32], 'flags': record[33],
                         'custom_data_hex': body[offset + 36:offset + 36 + custom_size].hex()})
        offset += 36 + custom_size
    if offset != len(body):
        raise ValueError('invalid PCBI package count or trailing data')
    return {'platform_id': body[0], 'header_data_hex': body[2:8].hex(),
            'packages': packages}


def decode_query(reply, command):
    if len(reply) < 16 or len(reply) > query_capacity(command):
        raise ValueError('invalid PCBI reply size')
    version, service, length, service_version, kind, reserved, echoed, result = \
        struct.unpack_from('<BBHBBHII', reply)
    if (version, service, service_version, kind, echoed) != (1, 1, 1, 2, command):
        raise ValueError('PCBI reply does not match the query')
    if length != len(reply) - 16:
        raise ValueError('invalid PCBI body length')
    if result != PCBI_SUCCESS:
        if length or len(reply) != 16:
            raise ValueError('invalid PCBI error reply')
        raise ValueError(f'PCBI query failed: {result:#010x}')
    if command == PCBI_DEVICE_INFO:
        return decode_device_info(reply[16:])
    if command == PCBI_ENUMERATE_VERSIONS:
        if length < 1 or reply[16] != length - 1:
            raise ValueError('invalid PCBI version count')
        return list(reply[17:])
    if length < 4:
        raise ValueError('missing PCBI service count')
    count = struct.unpack_from('<I', reply, 16)[0]
    if count * 2 + 4 != length:
        raise ValueError('invalid PCBI service count')
    return [{'id': reply[20 + 2 * index], 'version': reply[21 + 2 * index]}
            for index in range(count)]


def query_ioctl(fd, command):
    capacity = query_capacity(command)
    rx = ctypes.create_string_buffer(capacity)
    pointer = ctypes.addressof(rx)
    query = bytearray(struct.pack('<4IQ2I', command, capacity, 0, 0, pointer, 0, 0))
    fcntl.ioctl(fd, (3 << 30) | (len(query) << 16) | (ord('P') << 8) | 3,
                query, True)
    echoed, rx_size, actual, result, rx_ptr, reserved1, reserved2 = \
        struct.unpack('<4IQ2I', query)
    if (echoed != command or rx_size != capacity or rx_ptr != pointer or
            reserved1 or reserved2 or actual > capacity or result != PCBI_SUCCESS):
        raise ValueError('invalid kernel PCBI query result')
    return decode_query(rx.raw[:actual], command)


def read_ioctl(fd, number, size):
    buf = bytearray(size)
    fcntl.ioctl(fd, (2 << 30) | (size << 16) | (ord("P") << 8) | number, buf, True)
    return buf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/n1x-pluton")
    parser.add_argument('--services', action='store_true',
                        help='execute PCBI query-service command 5 to list service IDs and versions')
    parser.add_argument('--versions', action='store_true',
                        help='execute PCBI query-service command 7 to list protocol versions')
    parser.add_argument('--device-info', action='store_true',
                        help='query running firmware platform/package metadata with PCBI command 4')
    args = parser.parse_args()
    result = {"device": args.device}
    try:
        fd = os.open(args.device, os.O_RDONLY | os.O_CLOEXEC)
        try:
            values = struct.unpack("<8I", read_ioctl(fd, 0, 32))
            keys = ("abi_version", "boot_status", "register_stride", "transport_enabled",
                    "initialized", "poisoned", "last_pfi_status", "reserved")
            result.update(zip(keys, values))
            if result["abi_version"] != 1:
                raise ValueError("unsupported driver ABI")
            if args.services or args.versions or args.device_info:
                if not result['transport_enabled'] or result['poisoned']:
                    raise ValueError('PFI transport is disabled or in an uncertain state')
            if args.versions:
                result['pcbi_versions'] = query_ioctl(fd, PCBI_ENUMERATE_VERSIONS)
            if args.services:
                result['pcbi_services'] = query_ioctl(fd, PCBI_ENUMERATE_SERVICES)
            if args.device_info:
                result['pcbi_device_info'] = query_ioctl(fd, PCBI_DEVICE_INFO)
        finally:
            os.close(fd)
    except (OSError, ValueError) as error:
        result["error"] = str(error)
        print(json.dumps(result, indent=2))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
