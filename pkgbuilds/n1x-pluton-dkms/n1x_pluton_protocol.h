/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef N1X_PLUTON_PROTOCOL_H
#define N1X_PLUTON_PROTOCOL_H

#include <linux/types.h>
#ifdef __KERNEL__
#include <linux/errno.h>
#include <linux/string.h>
#else
#include <errno.h>
#include <stddef.h>
#include <string.h>
#endif

/* PFI v0 uses command 0x3f, at most 44 bytes per write fragment, and
 * 12-byte read-response headers. PCBI service framing is a separate layer.
 */
#define N1X_PFI_TX_FRAGMENT 44
#define N1X_PFI_RX_PACKET 16
#define N1X_PFI_MAX_MESSAGE 65536

static inline __u16 n1x_pfi_le16(const __u8 *p)
{
	return (__u16)p[0] | (__u16)p[1] << 8;
}

static inline __u32 n1x_pfi_le32(const __u8 *p)
{
	return (__u32)p[0] | (__u32)p[1] << 8 | (__u32)p[2] << 16 | (__u32)p[3] << 24;
}

static inline int n1x_pfi_write_packet(__u8 *packet, __u8 channel,
				      const __u8 *data, size_t length, int more)
{
	if (length > N1X_PFI_TX_FRAGMENT || (length && !data))
		return -EMSGSIZE;
	memset(packet, 0, 8 + N1X_PFI_TX_FRAGMENT);
	packet[1] = channel;
	packet[2] = 2 | (more ? 8 : 0);
	packet[6] = length;
	if (length)
		memcpy(packet + 8, data, length);
	return 8 + length;
}

static inline void n1x_pfi_read_packet(__u8 *packet, __u8 channel)
{
	memset(packet, 0, 8);
	packet[1] = channel;
	packet[2] = 1;
	packet[4] = 40;
}

static inline int n1x_pfi_decode_write(const __u8 *packet, size_t received,
				      __u32 *status)
{
	if (received < 12)
		return -EPROTO;
	*status = n1x_pfi_le32(packet + 4);
	return 0;
}

static inline int n1x_pfi_decode_read(const __u8 *packet, size_t received,
				     __u32 *status, __u16 *length, int *more)
{
	if (received < 12)
		return -EPROTO;
	*status = n1x_pfi_le32(packet);
	*length = n1x_pfi_le16(packet + 10);
	*more = n1x_pfi_le16(packet + 8) & 1;
	if (*length > received - 12)
		return -EPROTO;
	return 0;
}

#endif
