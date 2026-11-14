// SPDX-License-Identifier: GPL-2.0-only
/* N1X ROT1 mailbox/PFI transport for PCBI requests. */
#include <linux/acpi.h>
#include <linux/compat.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/unaligned.h>
#include <linux/vmalloc.h>

#include "n1x_pluton_protocol.h"
#include "n1x_pcbi_protocol.h"
#include "n1x_pluton_uapi.h"

#define N1X_ROT_IN_DATA 0x10
#define N1X_ROT_READY 0x20
#define N1X_ROT_IN_CONTROL 0x30
#define N1X_ROT_OUT_DATA 0x40
#define N1X_ROT_OUT_STATUS 0x50
#define N1X_ROT_OUT_ACK 0x60
#define N1X_ROT_SAFETY_DATA 0x70
#define N1X_ROT_SAFETY_STATUS 0x80
#define N1X_ROT_SAFETY_ACK 0x90
#define N1X_ROT_BOOT_STATUS 0xa0
#define N1X_ROT_ERROR_STATUS 0xb0
#define N1X_ROT_ERROR_CLEAR0 0xc0
#define N1X_ROT_ERROR_CLEAR1 0xd0
#define N1X_PFI_BUSY 4

static bool enable_transport;
module_param(enable_transport, bool, 0400);
MODULE_PARM_DESC(enable_transport, "Enable PFI mailbox transactions; disabled until explicitly requested");

struct n1x_pluton {
	struct kref reference;
	struct mutex lock;
	struct miscdevice misc;
	void __iomem *regs;
	u32 last_pfi_status;
	bool initialized;
	bool poisoned;
	bool removed;
	bool suspended;
};

struct n1x_pluton_transfer {
	u32 channel, tx_size, rx_size, rx_actual;
};

/* Resource 1 aliases register zero as stride metadata. The mailbox register
 * window starts at base+0x10 and ends at base+0xd3, excluding that alias.
 */
static void __iomem *n1x_rot_reg(struct n1x_pluton *p, unsigned int offset)
{
	return p->regs + (offset - N1X_ROT_IN_DATA);
}

static int n1x_rot_wait(struct n1x_pluton *p, unsigned int reg, unsigned long deadline)
{
	u32 value;
	unsigned long remaining;
	unsigned long now = jiffies;

	/* A second jiffies read could yield zero, disabling the poll timeout. */
	if (time_after_eq(now, deadline))
		return -ETIMEDOUT;
	remaining = jiffies_to_usecs(deadline - now);
	return readl_poll_timeout(n1x_rot_reg(p, reg), value, value & BIT(0), 1000, remaining);
}

static int n1x_rot_flush(struct n1x_pluton *p, unsigned int status, unsigned int ack)
{
	int limit;

	for (limit = 0; limit < 64; limit++) {
		if (!(ioread32(n1x_rot_reg(p, status)) & BIT(0)))
			return 0;
		iowrite32(1, n1x_rot_reg(p, ack));
		usleep_range(1000, 1500);
	}
	return -EBUSY;
}

static int n1x_rot_init(struct n1x_pluton *p, unsigned long deadline)
{
	int ret;

	if (p->removed || p->suspended)
		return -ENODEV;
	if (!enable_transport)
		return -EOPNOTSUPP;
	if (p->poisoned)
		return -ENOTRECOVERABLE;
	if (p->initialized)
		return 0;
	/* Initialize the host mailbox and acknowledge its stale FIFOs. */
	iowrite32(~0U, n1x_rot_reg(p, N1X_ROT_ERROR_CLEAR0));
	iowrite32(~0U, n1x_rot_reg(p, N1X_ROT_ERROR_CLEAR1));
	iowrite32(3, n1x_rot_reg(p, N1X_ROT_IN_CONTROL));
	ret = n1x_rot_flush(p, N1X_ROT_OUT_STATUS, N1X_ROT_OUT_ACK);
	if (!ret)
		ret = n1x_rot_flush(p, N1X_ROT_SAFETY_STATUS, N1X_ROT_SAFETY_ACK);
	if (!ret)
		ret = n1x_rot_wait(p, N1X_ROT_READY, deadline);
	if (!ret && (ioread32(n1x_rot_reg(p, N1X_ROT_ERROR_STATUS)) & 0xff))
		ret = -EIO;
	if (!ret)
		p->initialized = true;
	else
		p->poisoned = true;
	return ret;
}

static int n1x_rot_message(struct n1x_pluton *p, const u8 *message, size_t length,
			    u8 *reply, unsigned long deadline)
{
	u32 header, value;
	size_t offset;
	int ret;

	if (!length || length > 60)
		return -EMSGSIZE;
	ret = n1x_rot_wait(p, N1X_ROT_READY, deadline);
	if (ret)
		goto poison;
	/* PFI v0 uses command 0x3f, zero routing fields and a word-count
	 * header. A PFI packet contains at most 52 bytes.
	 */
	header = 0x3f | (DIV_ROUND_UP(length, 4) << 8);
	iowrite32(header, n1x_rot_reg(p, N1X_ROT_IN_DATA));
	for (offset = 0; offset < length; offset += 4) {
		u8 word[4] = { };

		memcpy(word, message + offset, min_t(size_t, 4, length - offset));
		iowrite32(get_unaligned_le32(word), n1x_rot_reg(p, N1X_ROT_IN_DATA));
	}
	/* Complete the FIFO writes before handing the request to firmware. */
	wmb();
	iowrite32(1, n1x_rot_reg(p, N1X_ROT_IN_CONTROL));
	ret = n1x_rot_wait(p, N1X_ROT_SAFETY_STATUS, deadline);
	if (ret)
		goto poison;
	/* Safety FIFO echoes the bitwise complement of the exact header and
	 * every padded payload word. Never bypass a mismatch or retry a command
	 * whose execution state is unknown.
	 */
	value = ioread32(n1x_rot_reg(p, N1X_ROT_SAFETY_DATA));
	if (~value != header) {
		ret = -EPROTO;
		goto poison;
	}
	for (offset = 0; offset < length; offset += 4) {
		u8 word[4] = { };

		memcpy(word, message + offset, min_t(size_t, 4, length - offset));
		value = ioread32(n1x_rot_reg(p, N1X_ROT_SAFETY_DATA));
		if (~value != get_unaligned_le32(word)) {
			ret = -EPROTO;
			goto poison;
		}
	}
	iowrite32(1, n1x_rot_reg(p, N1X_ROT_SAFETY_ACK));
	ret = n1x_rot_wait(p, N1X_ROT_OUT_STATUS, deadline);
	if (ret)
		goto poison;
	/* Each response occupies one 16-byte FIFO packet. */
	for (offset = 0; offset < N1X_PFI_RX_PACKET; offset += 4) {
		value = ioread32(n1x_rot_reg(p, N1X_ROT_OUT_DATA));
		put_unaligned_le32(value, reply + offset);
	}
	iowrite32(1, n1x_rot_reg(p, N1X_ROT_OUT_ACK));
	return 0;
poison:
	p->poisoned = true;
	return ret;
}

static int n1x_pfi_write(struct n1x_pluton *p, u8 channel, const u8 *data,
			 size_t length, unsigned long deadline)
{
	u8 packet[8 + N1X_PFI_TX_FRAGMENT], reply[N1X_PFI_RX_PACKET];
	size_t offset = 0;
	int ret, size;

	do {
		size_t count = min_t(size_t, length - offset, N1X_PFI_TX_FRAGMENT);

		size = n1x_pfi_write_packet(packet, channel, data + offset, count,
					    offset + count < length);
		if (size < 0)
			return size;
		ret = n1x_rot_message(p, packet, size, reply, deadline);
		if (ret)
			return ret;
		ret = n1x_pfi_decode_write(reply, sizeof(reply), &p->last_pfi_status);
		if (ret) {
			p->poisoned = true;
			return ret;
		}
		if (p->last_pfi_status) {
			/* A rejected continuation leaves an incomplete remote message.
			 * Do not let the next caller append an unrelated request to it.
			 */
			if (offset)
				p->poisoned = true;
			return -EREMOTEIO;
		}
		offset += count;
	} while (offset < length);
	return 0;
}

static int n1x_pfi_read(struct n1x_pluton *p, u8 channel, u8 *data,
			size_t capacity, u32 *actual, unsigned long deadline)
{
	u8 request[8], reply[N1X_PFI_RX_PACKET];
	size_t total = 0;
	u16 count;
	int ret, more;

	*actual = 0;
	n1x_pfi_read_packet(request, channel);
	do {
		ret = n1x_rot_message(p, request, sizeof(request), reply, deadline);
		if (ret)
			return ret;
		ret = n1x_pfi_decode_read(reply, sizeof(reply), &p->last_pfi_status, &count, &more);
		if (ret || total + count > N1X_PFI_MAX_MESSAGE) {
			p->poisoned = true;
			return ret ?: -EMSGSIZE;
		}
		if (p->last_pfi_status)
			return -EREMOTEIO;
		if (data && total < capacity)
			memcpy(data + total, reply + 12, min_t(size_t, count, capacity - total));
		total += count;
		/* Drain only the response belonging to our serialized request, even
		 * if the caller supplied too little space. Bound size and wall time.
		 */
		if (!count && more) {
			p->poisoned = true;
			return -EPROTO;
		}
	} while (more);
	*actual = total;
	return total > capacity ? -EMSGSIZE : 0;
}

static int n1x_pfi_channels(struct n1x_pluton *p, struct n1x_pluton_channels *channels,
			     unsigned long deadline)
{
	u8 command[4] = { };
	u32 actual;
	int ret;

	memset(channels, 0, sizeof(*channels));
	ret = n1x_pfi_write(p, 0, command, sizeof(command), deadline);
	if (ret == -EREMOTEIO && p->last_pfi_status == N1X_PFI_BUSY) {
		ret = n1x_pfi_read(p, 0, NULL, sizeof(channels->channel), &actual, deadline);
		if (!ret)
			ret = n1x_pfi_write(p, 0, command, sizeof(command), deadline);
	}
	if (ret)
		return ret;
	ret = n1x_pfi_read(p, 0, (u8 *)channels->channel, sizeof(channels->channel), &actual, deadline);
	if (ret)
		return ret;
	if (actual & 1) {
		p->poisoned = true;
		return -EPROTO;
	}
	channels->count = actual / 2;
	return 0;
}

static int n1x_pluton_rpc(struct n1x_pluton *p, struct n1x_pluton_transfer *exchange,
			  const u8 *tx, u8 *rx, unsigned long deadline)
{
	struct n1x_pluton_channels channels;
	unsigned int i;
	int ret;

	ret = n1x_pfi_channels(p, &channels, deadline);
	if (ret)
		return ret;
	for (i = 0; i < channels.count; i++)
		if (channels.channel[i].id == exchange->channel)
			break;
	if (i == channels.count || !(channels.channel[i].flags & BIT(0)))
		return -EBUSY;
	if (channels.channel[i].flags & BIT(1))
		return -EBUSY; /* Never discard another client's pending response. */
	ret = n1x_pfi_write(p, exchange->channel, tx, exchange->tx_size, deadline);
	if (ret)
		return ret;
	for (;;) {
		if (time_after_eq(jiffies, deadline)) {
			p->poisoned = true;
			return -ETIMEDOUT;
		}
		ret = n1x_pfi_channels(p, &channels, deadline);
		if (ret) {
			/* The RPC was submitted; its completion state is now unknown. */
			p->poisoned = true;
			return ret;
		}
		for (i = 0; i < channels.count; i++)
			if (channels.channel[i].id == exchange->channel &&
			    (channels.channel[i].flags & BIT(1)))
				return n1x_pfi_read(p, exchange->channel, rx, exchange->rx_size,
					    &exchange->rx_actual, deadline);
		usleep_range(1000, 2000);
	}
}

static long n1x_pluton_query_ioctl(struct n1x_pluton *p, void __user *user)
{
	struct n1x_pluton_query query;
	struct n1x_pluton_transfer exchange = {
		.channel = N1X_PCBI_QUERY_SERVICE,
		.tx_size = 12,
	};
	u8 tx[12], *rx;
	size_t capacity;
	unsigned long deadline;
	int ret;

	if (copy_from_user(&query, user, sizeof(query)))
		return -EFAULT;
	capacity = n1x_pcbi_query_capacity(query.command);
	if (!capacity || query.rx_size < 16 || query.rx_size > capacity ||
	    query.rx_actual || query.pcbi_result || query.reserved[0] || query.reserved[1])
		return -EINVAL;
	if (!query.rx_ptr || !access_ok(u64_to_user_ptr(query.rx_ptr), query.rx_size))
		return -EFAULT;
	rx = kvzalloc(capacity, GFP_KERNEL);
	if (!rx)
		return -ENOMEM;
	n1x_pcbi_query_request(tx, query.command);
	exchange.rx_size = capacity;
	ret = mutex_lock_interruptible(&p->lock);
	if (ret)
		goto free;
	deadline = jiffies + msecs_to_jiffies(10000);
	ret = n1x_rot_init(p, deadline);
	if (ret)
		goto unlock;
	ret = n1x_pluton_rpc(p, &exchange, tx, rx, deadline);
	if (ret)
		goto unlock;
	query.rx_actual = exchange.rx_actual;
	ret = n1x_pcbi_validate_reply(rx, exchange.rx_actual, query.command);
	if (ret == -EPROTO) {
		p->poisoned = true;
		goto unlock;
	}
	if (ret && ret != -EREMOTEIO)
		goto unlock;
	query.pcbi_result = n1x_pcbi_le32(rx + 12);
	if (!ret) {
		if (query.rx_actual > query.rx_size)
			ret = -EMSGSIZE;
		else if (copy_to_user(u64_to_user_ptr(query.rx_ptr), rx, query.rx_actual))
			ret = -EFAULT;
	}
unlock:
	mutex_unlock(&p->lock);
	if (copy_to_user(user, &query, sizeof(query)))
		ret = -EFAULT;
free:
	kvfree(rx);
	return ret;
}

static long n1x_pluton_ioctl(struct file *file, unsigned int command, unsigned long arg)
{
	struct n1x_pluton *p = file->private_data;
	void __user *user = (void __user *)arg;
	struct n1x_pluton_info info = { };
	int ret;

	if (command == N1X_PLUTON_CHANNELS)
		return -ENOTTY;
	if (command == N1X_PLUTON_QUERY)
		return n1x_pluton_query_ioctl(p, user);
	if (command != N1X_PLUTON_INFO)
		return -ENOTTY;
	ret = mutex_lock_interruptible(&p->lock);
	if (ret)
		return ret;
	if (p->removed || p->suspended) {
		ret = -ENODEV;
		goto unlock;
	}
	info.abi_version = 1;
	info.boot_status = ioread32(n1x_rot_reg(p, N1X_ROT_BOOT_STATUS));
	info.register_stride = 0x10;
	info.transport_enabled = enable_transport;
	info.initialized = p->initialized;
	info.poisoned = p->poisoned;
	info.last_pfi_status = p->last_pfi_status;
	ret = copy_to_user(user, &info, sizeof(info)) ? -EFAULT : 0;
unlock:
	mutex_unlock(&p->lock);
	return ret;
}

static void n1x_pluton_free(struct kref *reference)
{
	kfree(container_of(reference, struct n1x_pluton, reference));
}

static int n1x_pluton_open(struct inode *inode, struct file *file)
{
	struct n1x_pluton *p = container_of(file->private_data, struct n1x_pluton, misc);

	kref_get(&p->reference);
	file->private_data = p;
	return nonseekable_open(inode, file);
}

static int n1x_pluton_release(struct inode *inode, struct file *file)
{
	struct n1x_pluton *p = file->private_data;

	kref_put(&p->reference, n1x_pluton_free);
	return 0;
}

static const struct file_operations n1x_pluton_fops = {
	.owner = THIS_MODULE,
	.open = n1x_pluton_open,
	.release = n1x_pluton_release,
	.unlocked_ioctl = n1x_pluton_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
};

static int n1x_pluton_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct resource *regs, *stride;
	struct resource window = { .flags = IORESOURCE_MEM };
	struct n1x_pluton *p;
	unsigned long long revision;
	int ret;

	if (ACPI_FAILURE(acpi_evaluate_integer(ACPI_HANDLE(dev), "_HRV", NULL, &revision)) ||
	    revision != 1)
		return -ENODEV;
	regs = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	stride = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!regs || !stride || resource_size(regs) < N1X_ROT_ERROR_CLEAR1 + sizeof(u32) ||
	    stride->start != regs->start || resource_size(stride) != 0x10)
		return dev_err_probe(dev, -ENODEV, "unrecognized ROT1 mailbox resources\n");
	p = kzalloc_obj(*p);
	if (!p)
		return -ENOMEM;
	kref_init(&p->reference);
	mutex_init(&p->lock);
	window.start = regs->start + N1X_ROT_IN_DATA;
	window.end = regs->start + N1X_ROT_ERROR_CLEAR1 + sizeof(u32) - 1;
	window.name = dev_name(dev);
	p->regs = devm_ioremap_resource(dev, &window);
	if (IS_ERR(p->regs)) {
		ret = PTR_ERR(p->regs);
		goto put;
	}
	p->misc.minor = MISC_DYNAMIC_MINOR;
	p->misc.name = "n1x-pluton";
	p->misc.fops = &n1x_pluton_fops;
	p->misc.parent = dev;
	p->misc.mode = 0600;
	platform_set_drvdata(pdev, p);
	ret = misc_register(&p->misc);
	if (ret)
		goto put;
	dev_info(dev, "ROT1 diagnostic device registered; PFI transactions %s\n",
		 enable_transport ? "enabled on request" : "disabled");
	return 0;
put:
	kref_put(&p->reference, n1x_pluton_free);
	return ret;
}

static void n1x_pluton_remove(struct platform_device *pdev)
{
	struct n1x_pluton *p = platform_get_drvdata(pdev);

	misc_deregister(&p->misc);
	mutex_lock(&p->lock);
	p->removed = true;
	p->regs = NULL;
	mutex_unlock(&p->lock);
	kref_put(&p->reference, n1x_pluton_free);
}

static int n1x_pluton_suspend(struct device *dev)
{
	struct n1x_pluton *p = dev_get_drvdata(dev);

	mutex_lock(&p->lock);
	p->suspended = true;
	mutex_unlock(&p->lock);
	return 0;
}

static int n1x_pluton_resume(struct device *dev)
{
	struct n1x_pluton *p = dev_get_drvdata(dev);

	mutex_lock(&p->lock);
	p->suspended = false;
	p->initialized = false;
	mutex_unlock(&p->lock);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(n1x_pluton_pm, n1x_pluton_suspend, n1x_pluton_resume);

static const struct acpi_device_id n1x_pluton_ids[] = {
	{ "NVDA8601" },
	{ }
};
/* Explicit service loading only: no ACPI modalias autoload. */

static struct platform_driver n1x_pluton_driver = {
	.probe = n1x_pluton_probe,
	.remove = n1x_pluton_remove,
	.driver = {
		.name = "n1x-pluton",
		.acpi_match_table = n1x_pluton_ids,
		.pm = pm_sleep_ptr(&n1x_pluton_pm),
	},
};
module_platform_driver(n1x_pluton_driver);
MODULE_DESCRIPTION("N1X ROT1 PCBI query service and PFI transport");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.3.0");
