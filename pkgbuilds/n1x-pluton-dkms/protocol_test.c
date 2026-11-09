// SPDX-License-Identifier: GPL-2.0-only
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "n1x_pluton_protocol.h"
#include "n1x_pluton_uapi.h"
#include "n1x_pcbi_protocol.h"

_Static_assert(sizeof(struct n1x_pluton_info) == 32, "info ABI");
_Static_assert(sizeof(struct n1x_pluton_channels) == 40, "channels ABI");
_Static_assert(sizeof(struct n1x_pluton_query) == 32, "query ABI");
_Static_assert(N1X_PLUTON_QUERY == 0xc0205003U, "query ioctl number");

static void put32(__u8 *p, __u32 value)
{
	for (unsigned int i = 0; i < 4; i++)
		p[i] = value >> (8 * i);
}

static void test_pcbi(void)
{
	const __u8 versions[] = {1, 1, 2, 0, 1, 2, 0, 0, 7, 0, 0, 0,
				0xbd, 0xac, 0x86, 0x79, 1, 1};
	__u8 packet[4097] = {}, request[12], before[12];
	unsigned int command, i, j;
	size_t bytes;

	for (command = 0; command < 12; command++) {
		memset(request, 0xa5, sizeof(request));
		memcpy(before, request, sizeof(before));
		if (command == 4 || command == 5 || command == 7) {
			const __u8 expected[] = {1, 1, 0, 0, 1, 1, 0, 0, command, 0, 0, 0};

			assert(!n1x_pcbi_query_request(request, command));
			assert(!memcmp(request, expected, sizeof(request)));
		} else {
			assert(n1x_pcbi_query_request(request, command) == -EINVAL);
			assert(!memcmp(request, before, sizeof(request)));
		}
	}
	assert(n1x_pcbi_query_request(request, 0x10000004) == -EINVAL);
	assert(n1x_pcbi_query_request(NULL, 4) == -EINVAL);
	assert(n1x_pcbi_validate_reply(NULL, 16, 7) == -EINVAL);
	assert(!n1x_pcbi_validate_reply(versions, sizeof(versions), 7));
	for (bytes = 0; bytes < sizeof(versions); bytes++) {
		__u8 *short_packet = malloc(bytes ? bytes : 1);

		assert(short_packet);
		memcpy(short_packet, versions, bytes);
		assert(n1x_pcbi_validate_reply(short_packet, bytes, 7) == -EPROTO);
		free(short_packet);
	}
	for (i = 0; i < sizeof(versions); i++) {
		memcpy(packet, versions, sizeof(versions));
		packet[i] ^= 0x80;
		/* Reserved header bytes and version values are opaque. */
		assert(n1x_pcbi_validate_reply(packet, sizeof(versions), 7) ==
		       (i == 6 || i == 7 || i == 17 ? 0 : -EPROTO));
	}
	memcpy(packet, versions, sizeof(versions));
	packet[2] = 0;
	put32(packet + 12, 0x12345678);
	assert(n1x_pcbi_validate_reply(packet, 16, 7) == -EREMOTEIO);
	packet[2] = 2;
	assert(n1x_pcbi_validate_reply(packet, 18, 7) == -EPROTO);

	memcpy(packet, versions, 16);
	packet[8] = 5;
	packet[2] = 8;
	put32(packet + 16, 2);
	memcpy(packet + 20, (const __u8[]){1, 1, 2, 1}, 4);
	assert(!n1x_pcbi_validate_reply(packet, 24, 5));
	for (i = 0; i < 4; i++) {
		put32(packet + 16, (__u32[]){1, 3, 0x80000000, 0xffffffff}[i]);
		assert(n1x_pcbi_validate_reply(packet, 24, 5) == -EPROTO);
	}
	packet[2] = 5;
	put32(packet + 16, 0);
	assert(n1x_pcbi_validate_reply(packet, 21, 5) == -EPROTO);

	memset(packet, 0, sizeof(packet));
	memcpy(packet, versions, 16);
	packet[8] = 4;
	packet[2] = 52;
	packet[16] = 6;
	packet[17] = 1;
	memcpy(packet + 24, "PltnFull", 8);
	packet[56] = 1;
	packet[57] = 6;
	packet[58] = 8;
	assert(!n1x_pcbi_validate_reply(packet, 68, 4));
	for (bytes = 16; bytes < 68; bytes++) {
		__u8 *short_packet = malloc(bytes);

		assert(short_packet);
		memcpy(short_packet, packet, bytes);
		short_packet[2] = bytes - 16;
		assert(n1x_pcbi_validate_reply(short_packet, bytes, 4) == -EPROTO);
		free(short_packet);
	}
	for (i = 0; i < 6; i++) {
		const unsigned int offsets[] = {16, 17, 56, 57, 58, 58};
		const __u8 values[] = {0, 2, 0, 0xf0, 9, 65};
		__u8 old = packet[offsets[i]];

		packet[offsets[i]] = values[i];
		assert(n1x_pcbi_validate_reply(packet, 68, 4) == -EPROTO);
		packet[offsets[i]] = old;
	}
	memset(packet + 24, 0, 8);
	assert(n1x_pcbi_validate_reply(packet, 68, 4) == -EPROTO);
	/* Exercise the maximum number of minimum-sized package records. */
	memset(packet, 0, sizeof(packet));
	memcpy(packet, versions, 16);
	packet[8] = 4;
	packet[16] = 6;
	packet[17] = 113;
	for (i = 0; i < 113; i++) {
		packet[24 + 36 * i] = 1;
		packet[56 + 36 * i] = 1;
	}
	bytes = 24 + 36 * 113;
	packet[2] = bytes - 16;
	packet[3] = (bytes - 16) >> 8;
	assert(!n1x_pcbi_validate_reply(packet, bytes, 4));
	packet[17] = 114;
	assert(n1x_pcbi_validate_reply(packet, bytes, 4) == -EPROTO);
	for (i = 0; i < 8; i++) {
		__u32 seed = 0x86018901 + i;

		for (j = 0; j < sizeof(packet); j++) {
			seed = seed * 1664525U + 1013904223U;
			packet[j] = seed >> 24;
			assert(n1x_pcbi_validate_reply(packet, j, 4) < 0);
		}
	}
	puts("PCBI query vectors, complete reply validation, package bounds and ABI: PASS");
}

int main(void)
{
	const __u8 query[] = {0, 0, 0, 0};
	const __u8 write_expected[] = {0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 0, 0};
	const __u8 read_expected[] = {0, 7, 1, 0, 40, 0, 0, 0};
	__u8 packet[52], data[44], reply[16] = {0};
	__u32 status = 0, seed = 0x86018901;
	__u16 count = 0;
	int more = 0;
	size_t i, n;

	test_pcbi();

	assert(n1x_pfi_write_packet(packet, 0, query, sizeof(query), 0) == 12);
	assert(memcmp(packet, write_expected, sizeof(write_expected)) == 0);
	for (i = 12; i < sizeof(packet); i++)
		assert(packet[i] == 0);
	memset(data, 0xa5, sizeof(data));
	assert(n1x_pfi_write_packet(packet, 255, data, 44, 1) == 52);
	assert(packet[1] == 255 && packet[2] == 10 && packet[6] == 44);
	assert(memcmp(packet + 8, data, 44) == 0);
	assert(n1x_pfi_write_packet(packet, 0, data, 45, 0) == -EMSGSIZE);
	assert(n1x_pfi_write_packet(packet, 0, NULL, 1, 0) == -EMSGSIZE);
	n1x_pfi_read_packet(packet, 7);
	assert(memcmp(packet, read_expected, sizeof(read_expected)) == 0);

	/* Read and write replies deliberately put status at different offsets. */
	reply[0] = 0x78; reply[1] = 0x56; reply[2] = 0x34; reply[3] = 0x12;
	reply[4] = 4;
	assert(n1x_pfi_decode_write(reply, sizeof(reply), &status) == 0 && status == 4);
	reply[8] = 1; reply[10] = 4;
	assert(n1x_pfi_decode_read(reply, sizeof(reply), &status, &count, &more) == 0);
	assert(status == 0x12345678 && count == 4 && more == 1);
	reply[10] = 5;
	assert(n1x_pfi_decode_read(reply, sizeof(reply), &status, &count, &more) == -EPROTO);
	reply[10] = 0; reply[11] = 1;
	assert(n1x_pfi_decode_read(reply, sizeof(reply), &status, &count, &more) == -EPROTO);

	/* Exact-size allocations make truncated-packet reads visible to ASan.
	 * Exercise every header truncation and every possible fragment length.
	 */
	for (n = 0; n <= 16; n++) {
		__u8 *short_packet = malloc(n ? n : 1);

		assert(short_packet);
		for (i = 0; i < 4096; i++) {
			size_t j;
			int ret;

			for (j = 0; j < n; j++) {
				seed = seed * 1664525U + 1013904223U;
				short_packet[j] = seed >> 24;
			}
			ret = n1x_pfi_decode_write(short_packet, n, &status);
			assert(ret == (n < 12 ? -EPROTO : 0));
			ret = n1x_pfi_decode_read(short_packet, n, &status, &count, &more);
			if (n < 12)
				assert(ret == -EPROTO);
			else
				assert(ret == (n1x_pfi_le16(short_packet + 10) > n - 12 ? -EPROTO : 0));
		}
		free(short_packet);
	}
	puts("PFI wire vectors, truncated packets and ioctl layouts: PASS");
	return 0;
}
