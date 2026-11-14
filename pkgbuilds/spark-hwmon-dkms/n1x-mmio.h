/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SPBM_N1X_MMIO_H
#define SPBM_N1X_MMIO_H

/* P16 H7607BA model: firmware fields validated before MMIO registration. */
#define N1X_FIRST_LIMIT 9
#define N1X_LIMIT_CONFIG (HWMON_P_INPUT | HWMON_P_LABEL | HWMON_P_CAP | HWMON_P_MIN | HWMON_P_MAX)
static const struct {
	const char *label;
	u32 offset;
} n1x_mmio_power[] = {
	{ "sys_instant", 0x300 }, { "pkg_instant", 0x304 },
	{ "cpu_gpu", 0x308 }, { "cpu_p", 0x30c }, { "cpu_e", 0x310 },
	{ "vcore", 0x314 }, { "gpu", 0x324 }, { "prereg", 0x338 },
	{ "dc_input", 0x31c },
	{ "pl1", 0x800 }, { "pl2", 0x804 },
	{ "syspl1", 0x80c }, { "syspl2", 0x810 },
};
static const u32 n1x_limit_slots[] = { 0, 1, 4, 5 };
static const u32 n1x_limit_bounds[] = { 0x708, 0x718, 0x738, 0x748 };

static umode_t n1x_mmio_visible(const struct n1x_priv *p, u32 attr, int ch)
{
	if (!p->base || ch < 0 || ch >= ARRAY_SIZE(n1x_mmio_power))
		return 0;
	if (attr == hwmon_power_input || attr == hwmon_power_label)
		return 0444;
	if (ch >= N1X_FIRST_LIMIT) {
		if (attr == hwmon_power_cap)
			return 0444;
		if (attr == hwmon_power_min || attr == hwmon_power_max)
			return 0444;
	}
	return 0;
}

/* Validated reductions only: never exceed the current EC default or firmware ceiling. */
static u32 n1x_limit_max(const struct n1x_priv *p, int limit)
{
	return min(ioread32(p->base + n1x_limit_bounds[limit] + 4),
		   ioread32(p->base + 0x120 + n1x_limit_slots[limit] * 4));
}

static int n1x_mmio_read(struct n1x_priv *p, u32 attr, int ch, long *val)
{
	u32 raw, offset;
	int limit = ch - N1X_FIRST_LIMIT;

	if (!n1x_mmio_visible(p, attr, ch))
		return -EOPNOTSUPP;
	if (attr == hwmon_power_input)
		offset = n1x_mmio_power[ch].offset;
	else if (attr == hwmon_power_cap)
		offset = 0x160 + n1x_limit_slots[limit] * 4;
	else if (attr == hwmon_power_min)
		offset = n1x_limit_bounds[limit];
	else if (attr == hwmon_power_max) {
		*val = (long)n1x_limit_max(p, limit) * 1000;
		return 0;
	} else {
		return -EOPNOTSUPP;
	}
	raw = ioread32(p->base + offset);
	if (raw > 1000000)
		return -ENODATA;
	*val = (long)raw * 1000;
	return 0;
}

/* Raw words deliberately have no hwmon energy/voltage/alarm units. */
static ssize_t n1x_raw_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct n1x_priv *p = dev_get_drvdata(dev);
	u32 offset = to_sensor_dev_attr(attr)->index;

	return sysfs_emit(buf, "%u\n", ioread32(p->base + offset));
}
#define N1X_RAW(name, offset) static SENSOR_DEVICE_ATTR(name, 0444, n1x_raw_show, NULL, offset)
N1X_RAW(pl1_request_raw, 0x100);
N1X_RAW(pl2_request_raw, 0x104);
N1X_RAW(syspl1_request_raw, 0x110);
N1X_RAW(syspl2_request_raw, 0x114);
N1X_RAW(pkg_temperature_c_raw, 0x81c);
N1X_RAW(prochot_raw, 0x04c);
N1X_RAW(pl_level_raw, 0x048);
N1X_RAW(control_038_raw, 0x038);
N1X_RAW(diagnostic_380_raw, 0x380);
N1X_RAW(diagnostic_384_raw, 0x384);
N1X_RAW(diagnostic_388_raw, 0x388);
N1X_RAW(diagnostic_38c_raw, 0x38c);
N1X_RAW(pkg_energy_raw, 0x344);
N1X_RAW(pkg_energy_overflow_raw, 0x348);
N1X_RAW(pkg_energy_clear_raw, 0x34c);
N1X_RAW(cpu_e_energy_raw, 0x350);
N1X_RAW(cpu_e_energy_overflow_raw, 0x354);
N1X_RAW(cpu_e_energy_clear_raw, 0x358);
N1X_RAW(cpu_p_energy_raw, 0x35c);
N1X_RAW(cpu_p_energy_overflow_raw, 0x360);
N1X_RAW(cpu_p_energy_clear_raw, 0x364);
N1X_RAW(gpc_energy_raw, 0x368);
N1X_RAW(gpc_energy_overflow_raw, 0x36c);
N1X_RAW(gpc_energy_clear_raw, 0x370);
N1X_RAW(gpu_energy_raw, 0x374);
N1X_RAW(gpu_energy_overflow_raw, 0x378);
N1X_RAW(gpu_energy_clear_raw, 0x37c);
#undef N1X_RAW
#define N1X_ATTR(name) &sensor_dev_attr_##name.dev_attr.attr
static struct attribute *n1x_raw_attrs[] = {
	N1X_ATTR(pl1_request_raw), N1X_ATTR(pl2_request_raw),
	N1X_ATTR(syspl1_request_raw), N1X_ATTR(syspl2_request_raw),
	N1X_ATTR(pkg_temperature_c_raw),
	N1X_ATTR(prochot_raw), N1X_ATTR(pl_level_raw), N1X_ATTR(control_038_raw),
	N1X_ATTR(diagnostic_380_raw), N1X_ATTR(diagnostic_384_raw),
	N1X_ATTR(diagnostic_388_raw), N1X_ATTR(diagnostic_38c_raw),
	N1X_ATTR(pkg_energy_raw), N1X_ATTR(pkg_energy_overflow_raw), N1X_ATTR(pkg_energy_clear_raw),
	N1X_ATTR(cpu_e_energy_raw), N1X_ATTR(cpu_e_energy_overflow_raw), N1X_ATTR(cpu_e_energy_clear_raw),
	N1X_ATTR(cpu_p_energy_raw), N1X_ATTR(cpu_p_energy_overflow_raw), N1X_ATTR(cpu_p_energy_clear_raw),
	N1X_ATTR(gpc_energy_raw), N1X_ATTR(gpc_energy_overflow_raw), N1X_ATTR(gpc_energy_clear_raw),
	N1X_ATTR(gpu_energy_raw), N1X_ATTR(gpu_energy_overflow_raw), N1X_ATTR(gpu_energy_clear_raw),
	NULL,
};
#undef N1X_ATTR
static const struct attribute_group n1x_raw_group = { .attrs = n1x_raw_attrs };
static const struct attribute_group *n1x_raw_groups[] = { &n1x_raw_group, NULL };

static int n1x_mmio_init(struct device *dev, struct n1x_priv *p, acpi_handle handle)
{
	unsigned long long platform;
	void __iomem *base;
	u32 low, high, ec, effective;
	int i;

	/* Caller has checked the exact model and recognized MTEL schema. */
	if (ACPI_FAILURE(acpi_evaluate_integer(handle, "PLID", NULL, &platform)) ||
	    platform != 2)
		return dev_err_probe(dev, -ENODEV, "unvalidated N1X platform ID\n");
	base = devm_ioremap(dev, 0x1c238000, SPBM_SIZE);
	if (!base)
		return -ENOMEM;
	for (i = 0; i < ARRAY_SIZE(n1x_limit_slots); i++) {
		low = ioread32(base + n1x_limit_bounds[i]);
		high = ioread32(base + n1x_limit_bounds[i] + 4);
		ec = ioread32(base + 0x120 + n1x_limit_slots[i] * 4);
		effective = ioread32(base + 0x160 + n1x_limit_slots[i] * 4);
		if (!low || low > high || high > 250000 || ec < low || ec > high ||
		    effective < low || effective > high)
			return dev_err_probe(dev, -ENODEV, "invalid N1X limit contract\n");
	}
	if (ioread32(base + 0x818) < 2000 || ioread32(base + 0x818) > 4500)
		return dev_err_probe(dev, -ENODEV, "invalid N1X temperature contract\n");
	p->base = base;
	return 0;
}
#endif
