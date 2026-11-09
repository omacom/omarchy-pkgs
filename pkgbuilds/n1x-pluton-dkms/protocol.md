# PCBI query service

The transport binds to ACPI `NVDA8601`, checks revision 1 and maps the firmware
register resources. No product-name, BIOS-version or fixed physical-base check
is used.

The PFI transport and the PCBI service protocol are separate layers. PFI
channel status or a successful write does not establish PCBI request success.

The client reference is Microsoft's ARM64/ARM64X `plutonapi.dll`, pinned in
`config/platform-sources.json` with SHA256
`9ba962d073d097dbf558a21a33565d7780076e49ece0b4583f75ebe2d13a90fa`.
Its public symbols identify the following routines:

| Address | Routine |
| --- | --- |
| `0x18002df80` | `Pcbi1Query1EnumeratePcbiVersionsNoAlloc` |
| `0x18002e198` | `Pcbi1Query1EnumerateServicesNoAlloc` |
| `0x18002e698` | `Pcbi1Query1HotLoadDeviceInfo` |
| `0x18002e928` | `Pcbi1Query1ValidateDeviceInfo` |
| `0x18002ec80` | `Pcbi1ValidateRequestHeader1` |
| `0x18002eff8` | `Pcbi1ValidateResponseHeader1` |
| `0x18002f238` | `Pcbi1ValidateResponseHeader2` |

The decompilation is an analysis aid. Literal fields were also checked in the
original PE bytes and ARM64 instructions. The PE remains unchanged; no Windows
code is executed. Import/decompilation warnings in ARM64X exception metadata
are not evidence about firmware behavior.

## Request and response

The query request is 12 bytes:

| Offset | Width | Value |
| --- | --- | --- |
| 0 | u8 | PCBI version 1 |
| 1 | u8 | Query service ID 1, also the PFI channel |
| 2 | little-endian u16 | Body length 0 |
| 4 | u8 | Service version 1 |
| 5 | u8 | Request type 1 |
| 6 | u16 | Zeroed reserved bytes |
| 8 | little-endian u32 | Command 4: running firmware metadata; command 5: services; command 7: PCBI versions |

The eight-byte header literal at `0x18002e180` and `0x18002e398` is
`01 01 00 00 01 01 00 00`. Each caller appends the command as a 32-bit store.
The response header is 16 bytes: the same leading fields, response type 2,
an echoed command at offset 8, and a result code at offset 12. The client's
success literal is **`0x7986acbd`**, not zero. Transport status zero therefore
does not imply that the service request succeeded.

Command 7 returns a byte count followed by that many protocol-version bytes.
The client checks `total_bytes == count + 17` and that the header body length
matches the returned byte count. Command 5 returns a little-endian u32 count
followed by two-byte service-ID/service-version entries, requiring
`total_bytes == 20 + 2 * count` and the same body-length check. Error responses
have no body and are exactly 16 bytes.

Command 4 returns an eight-byte device header followed by variable-length
package records. Its first byte is a nonzero platform ID and its second is the
package count. Each record has a 36-byte fixed header: an eight-byte nonzero
name, 24 metadata bytes, a nonzero package type, flags whose high nibble is
zero, and a little-endian u16 custom-data length. Custom data is at most 64
bytes. The client checks every record's bounds and requires the count to
consume the entire response. Metadata remains hex because its complete field
semantics have not been established.

The Linux client implements these three query commands. Capability replies use
1024-byte private buffers; command 4 uses the reference client's 4096-byte
limit. Header, echoed command, result code, body length and array count are
validated before returning data. The existing kernel mutex
serializes PFI transactions and its deadline bounds completion. A disabled or
poisoned transport is rejected without submitting a service request.

## Linux query interface

`N1X_PLUTON_QUERY` (`0xc0205003`) accepts the 32-byte
`struct n1x_pluton_query` from `n1x_pluton_uapi.h`. Set `command` to 4, 5 or
7, `rx_ptr` to the response buffer and `rx_size` to its capacity. All other
fields must initially be zero. The descriptor has the same layout for
32-bit and 64-bit callers. The device node is root-only (`0600`).

The kernel constructs the request, selects query service 1 and receives
the complete response into a private buffer, independently of the caller's
buffer size. It validates the PCBI header and complete command body before
copying the wire response to the caller. `rx_actual` reports its size;
`pcbi_result` reports the service result after a valid response header and
body. Firmware-reserved bytes and package metadata remain opaque.

The minimum user buffer is 16 bytes. The maximum is 4096 for command 4 and
1024 for commands 5 and 7. A valid response larger than `rx_size` returns
`EMSGSIZE`, with `rx_actual` and `pcbi_result` updated and no response bytes
copied. A valid remote error returns `EREMOTEIO` and its result code, without
copying response bytes. Malformed replies return `EPROTO` and poison the
transport; subsequent queries fail with `ENOTRECOVERABLE`. Transport errors
are returned directly. User-copy failures return `EFAULT`; a fault can occur
after a query completed, so callers must not treat it as proof that no request
was sent. The driver does not resubmit failed queries automatically.

The CLI submits each typed query once and propagates errors. Command number 2
is reserved and returns `ENOTTY`; no raw userspace exchange is exposed.
The `enable_transport` parameter gates firmware transactions. Probe sends no
PCBI queries. The supported commands do not update firmware or keys.

The NVIDIA host API handles command 3 differently: at `0x1800325e8`,
`Pcbi1Query1ColdLoadDeviceInfo_PlutonFx_Usermode` synthesizes platform metadata
with an empty package list. The submit dispatcher at `0x1800313a8` routes that
query to the host implementation. It does not pass it to the firmware request
path used by command 4. Therefore the Linux client does not expose command 3 as
a firmware query. Neither metadata query is a firmware load/update operation.

## Qualification

`tests/test_pluton_services.py` covers literal request vectors, response
truncations, unmatched fields, count/length failures, remote errors and ioctl
buffer bounds. `protocol_test.c` validates the same kernel reply parser under
ASan/UBSan. `test_query.py` compiles the driver's actual ioctl and initialization
functions with mocked OS/RPC edges, exercising preflight rejection, terminal
states, reply and user-copy failures, rejection of reserved ioctls and eight concurrent
query callers. These are offline tests; live query results are recorded
separately. Other PCBI services, including key operations and firmware control,
are not implemented or exercised by this client.

`plutonhsprot.sys` and its symbols are also pinned as comparison inputs. Its
source paths identify an AMD ROT backend, so its mailbox implementation is
not an N1X hardware reference. In particular, its specialized response checker
for service `0xe0`, command `0x20`, must not replace the common PCBI checker.
