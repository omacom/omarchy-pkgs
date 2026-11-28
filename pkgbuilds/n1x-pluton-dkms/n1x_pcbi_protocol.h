/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef N1X_PCBI_PROTOCOL_H
#define N1X_PCBI_PROTOCOL_H

#include <linux/types.h>
#ifdef __KERNEL__
#include <linux/errno.h>
#include <linux/string.h>
#else
#include <errno.h>
#include <stddef.h>
#include <string.h>
#endif

#define N1X_PCBI_SUCCESS 0x7986acbdU
#define N1X_PCBI_QUERY_SERVICE 1U
#define N1X_PCBI_DEVICE_INFO 4U
#define N1X_PCBI_SERVICES 5U
#define N1X_PCBI_VERSIONS 7U

static inline __u16 n1x_pcbi_le16(const __u8 *p)
{
	return (__u16)p[0] | (__u16)p[1] << 8;
}

static inline __u32 n1x_pcbi_le32(const __u8 *p)
{
	return (__u32)p[0] | (__u32)p[1] << 8 | (__u32)p[2] << 16 | (__u32)p[3] << 24;
}

static inline size_t n1x_pcbi_query_capacity(__u32 command)
{
	switch (command) {
	case N1X_PCBI_DEVICE_INFO:
		return 4096;
	case N1X_PCBI_SERVICES:
	case N1X_PCBI_VERSIONS:
		return 1024;
	default:
		return 0;
	}
}

/* Unsupported commands leave the caller's packet unchanged. */
static inline int n1x_pcbi_query_request(__u8 *packet, __u32 command)
{
	__u8 request[12] = {1, N1X_PCBI_QUERY_SERVICE, 0, 0, 1, 1, 0, 0};

	if (!packet || !n1x_pcbi_query_capacity(command))
		return -EINVAL;
	request[8] = command;
	memcpy(packet, request, sizeof(request));
	return 0;
}

static inline int n1x_pcbi_validate_device_info(const __u8 *body, size_t bytes)
{
	size_t offset = 8;
	unsigned int i, j;

	if (!body || bytes < 8 || !body[0])
		return -EPROTO;
	for (i = 0; i < body[1]; i++) {
		const __u8 *record;
		__u16 custom;
		__u8 name = 0;

		if (bytes - offset < 36)
			return -EPROTO;
		record = body + offset;
		for (j = 0; j < 8; j++)
			name |= record[j];
		custom = n1x_pcbi_le16(record + 34);
		if (!name || !record[32] || (record[33] & 0xf0) ||
		    custom > 64 || custom > bytes - offset - 36)
			return -EPROTO;
		offset += 36 + custom;
	}
	return offset == bytes ? 0 : -EPROTO;
}

/* Header reserved bytes and package metadata are opaque. A valid remote
 * error has no body and returns -EREMOTEIO; malformed replies return -EPROTO.
 */
static inline int n1x_pcbi_validate_reply(const __u8 *packet, size_t bytes, __u32 command)
{
	size_t capacity = n1x_pcbi_query_capacity(command), length;

	if (!packet || !capacity)
		return -EINVAL;
	if (bytes < 16 || bytes > capacity)
		return -EPROTO;
	length = n1x_pcbi_le16(packet + 2);
	if (packet[0] != 1 || packet[1] != N1X_PCBI_QUERY_SERVICE ||
	    packet[4] != 1 || packet[5] != 2 ||
	    n1x_pcbi_le32(packet + 8) != command || length != bytes - 16)
		return -EPROTO;
	if (n1x_pcbi_le32(packet + 12) != N1X_PCBI_SUCCESS)
		return length ? -EPROTO : -EREMOTEIO;
	switch (command) {
	case N1X_PCBI_DEVICE_INFO:
		return n1x_pcbi_validate_device_info(packet + 16, length);
	case N1X_PCBI_VERSIONS:
		return length && packet[16] == length - 1 ? 0 : -EPROTO;
	case N1X_PCBI_SERVICES:
		if (length < 4 || n1x_pcbi_le32(packet + 16) != (length - 4) / 2 ||
		    ((length - 4) & 1))
			return -EPROTO;
		return 0;
	default:
		return -EINVAL;
	}
}

#endif
