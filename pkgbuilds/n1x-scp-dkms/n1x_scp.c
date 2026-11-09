// SPDX-License-Identifier: GPL-2.0-only
/* N1X SCP platform-firmware queries and firmware log reader. */
#include <linux/acpi.h>
#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/platform_device.h>
#include <linux/seq_file.h>
#include <linux/vmalloc.h>

/* Firmware owns SCP startup, power management and sensor calibration.
 * Mailbox queries require the FreeRTOS 2.0.8.0 dispatch ABI checked at probe.
 */
#define N1X_LOG_OFFSET 0x76054
#define N1X_LOG_HEADER_SIZE 0x10
#define N1X_LOG_RECORD_SIZE 0x80
#define N1X_LOG_MAGIC 0x5a5a5a5a
#define N1X_MBOX_IN_SET 0x100
#define N1X_MBOX_OUT_STATUS 0x104
#define N1X_MBOX_OUT_CLEAR 0x10c
#define N1X_MBOX_TIMEOUT_US 2000000

static bool enable_mailbox;
module_param(enable_mailbox, bool, 0400);
MODULE_PARM_DESC(enable_mailbox, "Enable bounded firmware queries on the supported SCP firmware");

struct n1x_scp_message {
	__le16 token;
	__le16 command;
	__le16 length;
	__le16 reserved;
	u8 payload[248];
};

struct n1x_scp {
	void __iomem *sram;
	resource_size_t size;
	struct dentry *debugfs;
	void __iomem *mailbox[2];
	struct mutex query_lock;
	u16 next_token;
	bool mailbox_poisoned;
	bool suspended;
};

static int n1x_scp_query(struct n1x_scp *scp, u16 command,
			const void *payload, u16 length,
			struct n1x_scp_message *reply)
{
	struct n1x_scp_message request = { };
	u32 status;
	int ret;

	if (!enable_mailbox)
		return -EOPNOTSUPP;
	if (command != 0 && command != 0x25 && command != 0x26)
		return -EOPNOTSUPP;
	if (length > sizeof(request.payload))
		return -EMSGSIZE;
	ret = mutex_lock_interruptible(&scp->query_lock);
	if (ret)
		return ret;
	if (scp->mailbox_poisoned) {
		ret = -ENOTRECOVERABLE;
		goto out;
	}
	if (scp->suspended) {
		ret = -EHOSTDOWN;
		goto out;
	}
	/* Do not clear or consume messages we did not initiate. */
	if (ioread32(scp->mailbox[0] + N1X_MBOX_IN_SET) ||
	    ioread32(scp->mailbox[1] + N1X_MBOX_OUT_STATUS)) {
		ret = -EBUSY;
		goto out;
	}
	if (++scp->next_token == 0xffff)
		scp->next_token = 1;
	request.token = cpu_to_le16(scp->next_token);
	request.command = cpu_to_le16(command);
	request.length = cpu_to_le16(length);
	if (length)
		memcpy(request.payload, payload, length);
	/* The payload aperture ends at the 0x100 doorbell register. Copy only
	 * the initialized packet; the header supplies its payload length.
	 */
	memcpy_toio(scp->mailbox[0], &request, round_up(8 + length, 4));
	/* Publish the complete request before ringing the firmware doorbell. */
	wmb();
	iowrite32(BIT(0), scp->mailbox[0] + N1X_MBOX_IN_SET);
	ret = readl_poll_timeout(scp->mailbox[1] + N1X_MBOX_OUT_STATUS,
				 status, status & BIT(0), 1000, N1X_MBOX_TIMEOUT_US);
	if (ret) {
		scp->mailbox_poisoned = true;
		goto out;
	}
	memcpy_fromio(reply, scp->mailbox[1], sizeof(*reply));
	if (reply->token != request.token || reply->command != request.command ||
	    le16_to_cpu(reply->length) > sizeof(reply->payload)) {
		scp->mailbox_poisoned = true;
		ret = -EPROTO;
		goto out;
	}
	/* Only acknowledge the channel after copying our matching response. */
	iowrite32(BIT(0), scp->mailbox[1] + N1X_MBOX_OUT_CLEAR);
	ret = 0;
out:
	mutex_unlock(&scp->query_lock);
	return ret;
}

static int n1x_scp_version_show(struct seq_file *seq, void *unused)
{
	struct n1x_scp_message reply;
	int ret = n1x_scp_query(seq->private, 0, NULL, 0, &reply);

	if (ret)
		return ret;
	seq_printf(seq, "%.*s\n", le16_to_cpu(reply.length), reply.payload);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(n1x_scp_version);

static int n1x_scp_sensors_show(struct seq_file *seq, void *unused)
{
	struct n1x_scp *scp = seq->private;
	struct n1x_scp_message reply;
	u8 id, count;
	int ret = n1x_scp_query(scp, 0x25, NULL, 0, &reply);

	if (ret)
		return ret;
	if (le16_to_cpu(reply.length) != 1 || reply.payload[0] != 2)
		return -EPROTO;
	count = reply.payload[0];
	seq_printf(seq, "descriptor_slots=%u\n", count);
	/* Slot zero is empty in firmware 2.0.8.0. Slot one is the VEML3328.
	 * Firmware's 0x26 handler has no bounds check, so never accept a raw
	 * caller-provided index or use an unvalidated firmware count here.
	 */
	for (id = 1; id < count; id++) {
		int byte;

		ret = n1x_scp_query(scp, 0x26, &id, sizeof(id), &reply);
		if (ret)
			return ret;
		if (le16_to_cpu(reply.length) != 121 || reply.payload[0] != id)
			return -EPROTO;
		seq_printf(seq, "slot=%u descriptor=", id);
		for (byte = 1; byte <= 120; byte++)
			seq_printf(seq, "%02x", reply.payload[byte]);
		seq_putc(seq, '\n');
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(n1x_scp_sensors);

static int n1x_log_header(struct n1x_scp *scp, u32 *count, u16 *capacity)
{
	void __iomem *header = scp->sram + N1X_LOG_OFFSET;

	if (ioread16(header) != 0x100 || ioread32(header + 4) != N1X_LOG_MAGIC)
		return -ENODATA;
	*count = ioread32(header + 8);
	*capacity = ioread16(header + 12);
	if (!*capacity || *capacity >
	    (scp->size - N1X_LOG_OFFSET - N1X_LOG_HEADER_SIZE) / N1X_LOG_RECORD_SIZE)
		return -EOVERFLOW;
	return 0;
}

static int n1x_scp_status_show(struct seq_file *seq, void *unused)
{
	struct n1x_scp *scp = seq->private;
	u32 count;
	u16 capacity;
	int ret = n1x_log_header(scp, &count, &capacity);

	if (ret)
		return ret;
	seq_printf(seq, "firmware_log_records=%u\nfirmware_log_capacity=%u\n", count, capacity);
	seq_puts(seq, "firmware_lifecycle=platform-owned\n");
	seq_printf(seq, "mailbox_queries=%s\n", !enable_mailbox ? "disabled" :
		   READ_ONCE(scp->mailbox_poisoned) ? "failed" : "enabled");
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(n1x_scp_status);

static int n1x_scp_log_show(struct seq_file *seq, void *unused)
{
	struct n1x_scp *scp = seq->private;
	char record[N1X_LOG_RECORD_SIZE];
	u32 count, index, begin;
	u16 capacity;
	int ret = n1x_log_header(scp, &count, &capacity);

	if (ret)
		return ret;
	begin = count > capacity ? count - capacity : 0;
	for (index = begin; index < count; index++) {
		void __iomem *entry = scp->sram + N1X_LOG_OFFSET + N1X_LOG_HEADER_SIZE +
			(index % capacity) * N1X_LOG_RECORD_SIZE;

		memcpy_fromio(record, entry, sizeof(record));
		seq_write(seq, record, strnlen(record, sizeof(record)));
	}
	/* Firmware can append while reading: this is a bounded snapshot, not a
	 * promise of a transactionally consistent log or a destructive log drain.
	 */
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(n1x_scp_log);

/* Each open owns a bounded SRAM copy rather than a devm MMIO pointer.
 * The protected debugfs open synchronizes the copy with device removal.
 */
struct n1x_scp_snapshot {
	size_t bytes;
	u8 data[];
};

static int n1x_scp_snapshot_open(struct inode *inode, struct file *file)
{
	struct n1x_scp *scp = inode->i_private;
	struct n1x_scp_snapshot *snapshot;

	snapshot = kvmalloc(struct_size(snapshot, data, scp->size), GFP_KERNEL);

	if (!snapshot)
		return -ENOMEM;
	snapshot->bytes = scp->size;
	memcpy_fromio(snapshot->data, scp->sram, snapshot->bytes);
	file->private_data = snapshot;
	return 0;
}

static ssize_t n1x_scp_snapshot_read(struct file *file, char __user *buf,
				   size_t count, loff_t *pos)
{
	struct n1x_scp_snapshot *snapshot = file->private_data;

	return simple_read_from_buffer(buf, count, pos, snapshot->data, snapshot->bytes);
}

static int n1x_scp_snapshot_release(struct inode *inode, struct file *file)
{
	kvfree(file->private_data);
	return 0;
}

static const struct file_operations n1x_scp_snapshot_fops = {
	.owner = THIS_MODULE,
	.open = n1x_scp_snapshot_open,
	.read = n1x_scp_snapshot_read,
	.release = n1x_scp_snapshot_release,
	.llseek = default_llseek,
};

static void n1x_scp_debugfs_remove(void *data)
{
	debugfs_remove_recursive(data);
}

static int n1x_scp_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct n1x_scp *scp;
	struct resource *sram;
	u32 count;
	u16 capacity;
	int ret;

	sram = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!sram || resource_size(sram) <
	    N1X_LOG_OFFSET + N1X_LOG_HEADER_SIZE + N1X_LOG_RECORD_SIZE)
		return dev_err_probe(dev, -ENODEV, "unrecognized SCP SRAM resource\n");
	scp = devm_kzalloc(dev, sizeof(*scp), GFP_KERNEL);
	if (!scp)
		return -ENOMEM;
	scp->size = resource_size(sram);
	mutex_init(&scp->query_lock);
	scp->sram = devm_ioremap_resource(dev, sram);
	if (IS_ERR(scp->sram))
		return PTR_ERR(scp->sram);
	ret = n1x_log_header(scp, &count, &capacity);
	if (ret)
		return dev_err_probe(dev, ret, "platform SCP firmware log is not available\n");
	if (enable_mailbox) {
		/* Match the 2.0.8.0 dispatch and reply-header instructions before
		 * enabling queries. Hardware IDs do not identify the firmware ABI.
		 */
		static const u8 dispatch[] = {
			0x63, 0x88, 0x2a, 0x46, 0x39, 0x46, 0x02, 0x20,
			0x03, 0xf0, 0x5b, 0xfe, 0xb4, 0xf8, 0x02, 0x80,
		};
		u8 observed[sizeof(dispatch)];
		unsigned int i;

		memcpy_fromio(observed, scp->sram + 0x41ce, sizeof(observed));
		if (memcmp(observed, dispatch, sizeof(dispatch)))
			return dev_err_probe(dev, -ENODEV, "unrecognized SCP firmware dispatch ABI\n");
		for (i = 0; i < ARRAY_SIZE(scp->mailbox); i++) {
			struct resource *res = platform_get_resource(pdev, IORESOURCE_MEM, i + 3);

			if (!res || resource_size(res) < N1X_MBOX_OUT_CLEAR + sizeof(u32))
				return dev_err_probe(dev, -ENODEV, "unrecognized SCP mailbox resource\n");
			scp->mailbox[i] = devm_ioremap_resource(dev, res);
			if (IS_ERR(scp->mailbox[i]))
				return PTR_ERR(scp->mailbox[i]);
		}
	}
	platform_set_drvdata(pdev, scp);
	scp->debugfs = debugfs_create_dir("n1x_scp", NULL);
	if (IS_ERR(scp->debugfs))
		return PTR_ERR(scp->debugfs);
	ret = devm_add_action_or_reset(dev, n1x_scp_debugfs_remove, scp->debugfs);
	if (ret)
		return ret;
	debugfs_create_file("status", 0400, scp->debugfs, scp, &n1x_scp_status_fops);
	debugfs_create_file("firmware_log", 0400, scp->debugfs, scp, &n1x_scp_log_fops);
	debugfs_create_file("sram_snapshot", 0400, scp->debugfs, scp, &n1x_scp_snapshot_fops);
	debugfs_create_file("firmware_version", 0400, scp->debugfs, scp, &n1x_scp_version_fops);
	debugfs_create_file("sensor_descriptors", 0400, scp->debugfs, scp, &n1x_scp_sensors_fops);
	dev_info(dev, "platform SCP log: %u records, capacity %u; queries %s\n",
		 count, capacity, enable_mailbox ? "enabled" : "disabled");
	return 0;
}

static int n1x_scp_suspend(struct device *dev)
{
	struct n1x_scp *scp = dev_get_drvdata(dev);

	mutex_lock(&scp->query_lock);
	scp->suspended = true;
	mutex_unlock(&scp->query_lock);
	return 0;
}

static int n1x_scp_resume(struct device *dev)
{
	struct n1x_scp *scp = dev_get_drvdata(dev);

	mutex_lock(&scp->query_lock);
	scp->suspended = false;
	mutex_unlock(&scp->query_lock);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(n1x_scp_pm, n1x_scp_suspend, n1x_scp_resume);

static const struct acpi_device_id n1x_scp_ids[] = {
	{ "NVDA8200" },
	{ }
};
/* Explicit service loading only: no ACPI modalias autoload. */

static struct platform_driver n1x_scp_driver = {
	.probe = n1x_scp_probe,
	.driver = {
		.name = "n1x-scp",
		.acpi_match_table = n1x_scp_ids,
		.pm = pm_sleep_ptr(&n1x_scp_pm),
	},
};
module_platform_driver(n1x_scp_driver);
MODULE_DESCRIPTION("N1X SCP firmware queries and log reader");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.2.0");
