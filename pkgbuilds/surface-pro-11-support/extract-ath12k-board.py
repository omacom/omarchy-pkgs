#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brandon Williams

"""Extract one exact board record from an ath12k board-2.bin container."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import struct
import tempfile


# The magic is 17 bytes; the first IE starts at the next 4-byte boundary,
# as in the kernel's ath12k_core_fetch_board_data_api_n().
SIGNATURE = b"QCA-ATH12K-BOARD\0"
FIRST_IE = (len(SIGNATURE) + 3) & ~3
IE_HEADER = struct.Struct("<II")
TOP_LEVEL_BOARD = 0
BOARD_NAME = 0
BOARD_DATA = 1
MAX_CONTAINER_BYTES = 16 * 1024 * 1024
MAX_RECORD_BYTES = 1024 * 1024


class ContainerError(ValueError):
    """The board container is malformed or does not satisfy the contract."""


def padded_length(length: int) -> int:
    return (length + 3) & ~3


def iter_ies(data: bytes, start: int, length: int):
    end = start + length
    if start < 0 or length < 0 or end > len(data):
        raise ContainerError("IE range is outside the container")

    offset = start
    while offset < end:
        if end - offset < IE_HEADER.size:
            raise ContainerError("truncated IE header")
        ie_type, ie_length = IE_HEADER.unpack_from(data, offset)
        offset += IE_HEADER.size
        padded = padded_length(ie_length)
        if padded > end - offset:
            raise ContainerError("IE payload is outside its parent")
        yield ie_type, data[offset : offset + ie_length]
        offset += padded

    if offset != end:
        raise ContainerError("misaligned IE sequence")


def extract_record(container: bytes, requested_name: str) -> bytes:
    if not requested_name or "\0" in requested_name:
        raise ContainerError("invalid requested board name")
    if len(container) > MAX_CONTAINER_BYTES:
        raise ContainerError("board container exceeds the safety limit")
    if not container.startswith(SIGNATURE):
        raise ContainerError("invalid ath12k board container signature")

    matches: list[bytes] = []
    for ie_type, board_payload in iter_ies(
        container, FIRST_IE, len(container) - FIRST_IE
    ):
        if ie_type != TOP_LEVEL_BOARD:
            continue

        names: list[str] = []
        board_data: bytes | None = None
        for child_type, child_payload in iter_ies(
            board_payload, 0, len(board_payload)
        ):
            if child_type == BOARD_NAME:
                try:
                    names.append(child_payload.decode("ascii"))
                except UnicodeDecodeError as error:
                    raise ContainerError("non-ASCII board name") from error
            elif child_type == BOARD_DATA:
                if board_data is not None:
                    raise ContainerError("board record has multiple data IEs")
                if len(child_payload) > MAX_RECORD_BYTES:
                    raise ContainerError("board record exceeds the safety limit")
                board_data = child_payload

        if requested_name in names:
            if board_data is None:
                raise ContainerError("matching board record has no data")
            matches.append(board_data)

    if len(matches) != 1:
        raise ContainerError(
            f"expected one matching board record, found {len(matches)}"
        )
    return matches[0]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract one named record from an ath12k board-2.bin"
    )
    parser.add_argument("container", type=Path)
    parser.add_argument("record_name")
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-bytes", type=int, required=True)
    parser.add_argument("--expected-sha256", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.expected_bytes < 1 or args.expected_bytes > MAX_RECORD_BYTES:
        raise SystemExit("invalid expected output size")
    if (
        len(args.expected_sha256) != 64
        or any(character not in "0123456789abcdef" for character in args.expected_sha256)
    ):
        raise SystemExit("invalid expected SHA-256")
    if not args.container.is_file() or args.container.is_symlink():
        raise SystemExit(f"unsafe or missing input: {args.container}")
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit(f"refusing existing output: {args.output}")

    record = extract_record(args.container.read_bytes(), args.record_name)
    actual_sha256 = hashlib.sha256(record).hexdigest()
    if len(record) != args.expected_bytes or actual_sha256 != args.expected_sha256:
        raise SystemExit(
            "extracted board identity mismatch: "
            f"{len(record)} bytes, SHA-256 {actual_sha256}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{args.output.name}.", dir=args.output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output_file:
            output_file.write(record)
            output_file.flush()
            os.fsync(output_file.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, args.output)
    finally:
        if temporary.exists():
            temporary.unlink()

    print(
        f"Extracted {args.record_name} to {args.output}: "
        f"{len(record)} bytes, SHA-256 {actual_sha256}"
    )


if __name__ == "__main__":
    main()
