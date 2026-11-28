/* SPDX-License-Identifier: GPL-2.0 */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

typedef uint32_t u32;
typedef uint64_t u64;
typedef unsigned int umode_t;
#define __iomem
typedef void *acpi_handle;
typedef char *acpi_string;
typedef int acpi_status;
typedef int acpi_object_type;

#define U32_MAX UINT32_MAX
#define SPBM_SIZE 0x1000
#define ACPI_TYPE_INTEGER 1
#define ACPI_TYPE_STRING 2
#define ACPI_TYPE_PACKAGE 3
#define ACPI_TYPE_THERMAL 4
#define ACPI_FAILURE(status) ((status) != 0)
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define BIT(bit) (1UL << (bit))
#define GENMASK(high, low) \
	(((~0UL) >> (sizeof(unsigned long) * 8 - 1 - (high))) & (~0UL << (low)))

enum { hwmon_power_input = 1, hwmon_power_label, hwmon_power_cap,
       hwmon_power_min, hwmon_power_max };
struct device { int unused; };
struct attribute { int unused; };
struct device_attribute { struct attribute attr; };
struct sensor_dev_attr { struct device_attribute dev_attr; u32 index; };
struct attribute_group { struct attribute **attrs; };

#define HWMON_P_INPUT (1U << 0)
#define HWMON_P_LABEL (1U << 1)
#define HWMON_P_CAP (1U << 2)
#define HWMON_P_MIN (1U << 3)
#define HWMON_P_MAX (1U << 4)
#define min(a, b) ((a) < (b) ? (a) : (b))
#define SENSOR_DEVICE_ATTR(name, mode, show, store, value) \
	struct sensor_dev_attr sensor_dev_attr_##name = { .index = (value) }
#define to_sensor_dev_attr(attribute) \
	((struct sensor_dev_attr *)((char *)(attribute) - offsetof(struct sensor_dev_attr, dev_attr.attr)))

union acpi_object {
	acpi_object_type type;
	struct { acpi_object_type type; u64 value; } integer;
	struct { acpi_object_type type; char *pointer; } string;
	struct { acpi_object_type type; u32 count; union acpi_object *elements; } package;
};
struct guid_t { int unused; };
static const struct guid_t mtel_dsm_guid;

static bool dsm_supported;
static int spbm_resource_index;
static int function2_index;
static unsigned int function2_calls, acpi_free_calls;
static union acpi_object function2_result, function2_entries[12];
static bool sensor_exists, sensor_has_tmp, mapping_fails;
static acpi_object_type sensor_type;
static acpi_status sensor_status;
static u64 sensor_value, sensor_critical, platform_id;
static unsigned char mapped_window[SPBM_SIZE];
static u32 registers[SPBM_SIZE / sizeof(u32)];
static unsigned long long mapped_physical;
static size_t mapped_length;
static unsigned int mmio_reads, mmio_writes;

enum schema_shape {
	SCHEMA_VALID, SCHEMA_BAD_PACKAGE_TYPE, SCHEMA_ODD_ENTRY_COUNT,
	SCHEMA_BAD_NAME_TYPE, SCHEMA_BAD_OFFSET_TYPE, SCHEMA_DUPLICATE_KEY,
	SCHEMA_MISSING_KEY, SCHEMA_UNALIGNED_OFFSET, SCHEMA_OVERSIZED_OFFSET,
	SCHEMA_UNKNOWN_KEY
};

static int spbm_dsm_find_resource(acpi_handle handle, const char *name)
{
	(void)handle;
	assert(strcmp(name, "SPBM") == 0);
	return spbm_resource_index;
}
static bool acpi_check_dsm(acpi_handle h, const struct guid_t *g, int r, unsigned long f)
{
	(void)h; (void)g;
	assert(r == 0 && f == (BIT(1) | BIT(2)));
	return dsm_supported;
}
static void mock_acpi_free(union acpi_object *object)
{
	assert(object == &function2_result);
	acpi_free_calls++;
}
#define ACPI_FREE(object) mock_acpi_free(object)
static union acpi_object *acpi_evaluate_dsm(acpi_handle h, const struct guid_t *g,
					     int revision, int function,
					     union acpi_object *argument)
{
	(void)h; (void)g;
	assert(revision == 0 && function == 2 && argument->package.count == 1);
	function2_calls++;
	return (int)argument->package.elements[0].integer.value == function2_index ?
		&function2_result : NULL;
}
static acpi_status acpi_get_handle(acpi_handle parent, acpi_string path, acpi_handle *out)
{
	(void)parent; (void)path;
	if (!sensor_exists)
		return 1;
	*out = (acpi_handle)(uintptr_t)0x1234;
	return 0;
}
static acpi_status acpi_get_type(acpi_handle h, acpi_object_type *type)
{
	(void)h; *type = sensor_type; return 0;
}
static bool acpi_has_method(acpi_handle h, const char *method)
{
	(void)h; assert(strcmp(method, "_TMP") == 0); return sensor_has_tmp;
}
static acpi_status acpi_evaluate_integer(acpi_handle h, const char *method, void *args,
					  unsigned long long *value)
{
	(void)args;
	if (h == (acpi_handle)(uintptr_t)0x1234) {
		if (!strcmp(method, "_TMP")) *value = sensor_value;
		else if (!strcmp(method, "_CRT")) *value = sensor_critical;
		else return 1;
		return sensor_status;
	}
	assert(strcmp(method, "PLID") == 0);
	*value = platform_id;
	return sensor_status;
}
static u32 mock_ioread32(const volatile void *address)
{
	const volatile unsigned char *p = address;
	ptrdiff_t offset = p - mapped_window;
	assert(offset >= 0 && (size_t)offset + sizeof(u32) <= sizeof(mapped_window));
	assert(offset % sizeof(u32) == 0);
	mmio_reads++;
	return registers[(size_t)offset / sizeof(u32)];
}
static void mock_iowrite32(u32 value, volatile void *address)
{
	(void)value; (void)address; mmio_writes++;
}
#define ioread32(address) mock_ioread32(address)
#define iowrite32(value, address) mock_iowrite32(value, address)
static void __iomem *devm_ioremap(struct device *dev, unsigned long long phys, size_t size)
{
	(void)dev; mapped_physical = phys; mapped_length = size;
	return mapping_fails ? NULL : mapped_window;
}
static int dev_err_probe(struct device *dev, int error, const char *format, ...)
{
	(void)dev; (void)format; return error;
}
static int sysfs_emit(char *buf, const char *format, unsigned int value)
{
	return sprintf(buf, format, value);
}
static void *dev_get_drvdata(struct device *dev)
{
	(void)dev;
	return NULL;
}

struct n1x_priv { void __iomem *base; };
#include "n1x-acpi.h"
#include "n1x-mmio.h"

static void reset_mocks(void)
{
	dsm_supported = true; spbm_resource_index = 0; function2_index = 0;
	function2_calls = 0; acpi_free_calls = 0; sensor_exists = true;
	sensor_has_tmp = true; sensor_type = ACPI_TYPE_THERMAL; sensor_status = 0;
	sensor_value = 3200; sensor_critical = 0x7fffffff; platform_id = 2;
	mapping_fails = false; mapped_physical = 0; mapped_length = 0;
	mmio_reads = 0; mmio_writes = 0; memset(registers, 0, sizeof(registers));
}
static void setup_schema(enum schema_shape shape)
{
	static char *keys[] = { "CFL", "CPL", "CBL", "CCI", "CPI" };
	int count = 10;
	memset(function2_entries, 0, sizeof(function2_entries));
	function2_result.type = ACPI_TYPE_PACKAGE;
	function2_result.package.type = ACPI_TYPE_PACKAGE;
	function2_result.package.elements = function2_entries;
	for (int i = 0; i < 5; i++) {
		function2_entries[2*i].type = ACPI_TYPE_STRING;
		function2_entries[2*i].string.pointer = keys[i];
		function2_entries[2*i+1].type = ACPI_TYPE_INTEGER;
		function2_entries[2*i+1].integer.value = 0x100 + i*4;
	}
	switch (shape) {
	case SCHEMA_BAD_PACKAGE_TYPE: function2_result.type = ACPI_TYPE_INTEGER; break;
	case SCHEMA_ODD_ENTRY_COUNT: count = 9; break;
	case SCHEMA_BAD_NAME_TYPE: function2_entries[0].type = ACPI_TYPE_INTEGER; break;
	case SCHEMA_BAD_OFFSET_TYPE: function2_entries[1].type = ACPI_TYPE_STRING; break;
	case SCHEMA_DUPLICATE_KEY:
		function2_entries[10] = function2_entries[0];
		function2_entries[11] = function2_entries[1]; count = 12; break;
	case SCHEMA_MISSING_KEY: count = 8; break;
	case SCHEMA_UNALIGNED_OFFSET: function2_entries[1].integer.value = 0x103; break;
	case SCHEMA_OVERSIZED_OFFSET:
		function2_entries[1].integer.value = (u64)U32_MAX + 1; break;
	case SCHEMA_UNKNOWN_KEY:
		function2_entries[0].string.pointer = "NOT_A_REQUIRED_KEY"; break;
	case SCHEMA_VALID: default: break;
	}
	function2_result.package.count = count;
}
static void set_valid_limits(void)
{
	for (int i=0; i<ARRAY_SIZE(n1x_limit_slots); i++) {
		registers[n1x_limit_bounds[i]/4] = 10000;
		registers[(n1x_limit_bounds[i]+4)/4] = 250000;
		registers[(0x120+n1x_limit_slots[i]*4)/4] = 120000;
		registers[(0x160+n1x_limit_slots[i]*4)/4] = 100000;
	}
	registers[0x818/4] = 3200;
}
static int init_mmio(struct n1x_priv *priv)
{
	struct device dev = {0};
	return n1x_mmio_init(&dev, priv, (acpi_handle)(uintptr_t)0x9876);
}

static void test_schema_accepts_nonzero_subindex(void)
{
	reset_mocks(); function2_index = 5; setup_schema(SCHEMA_VALID);
	assert(n1x_supported_schema(NULL));
	assert(function2_calls == 6 && acpi_free_calls == 1);
}
static void test_schema_requires_dsm_and_named_resource(void)
{
	reset_mocks(); dsm_supported = false; setup_schema(SCHEMA_VALID);
	assert(!n1x_supported_schema(NULL) && function2_calls == 0);
	reset_mocks(); spbm_resource_index = -1; setup_schema(SCHEMA_VALID);
	assert(!n1x_supported_schema(NULL) && function2_calls == 0);
}
static void test_schema_rejects_malformed_entries(void)
{
	for (enum schema_shape shape=SCHEMA_BAD_PACKAGE_TYPE; shape<=SCHEMA_UNKNOWN_KEY; shape++) {
		reset_mocks(); setup_schema(shape);
		assert(!n1x_supported_schema(NULL));
		assert(acpi_free_calls == 1);
	}
}
static void test_thermal_sensor_type_and_power_units_are_gated(void)
{
	reset_mocks();
	assert(!n1x_find_sensor("\\_TZ.PSYS", true, false));
	assert(n1x_find_sensor("\\_TZ.PSYS", true, true));
	sensor_critical = 99; assert(!n1x_find_sensor("\\_TZ.PSYS", true, true));
	sensor_type = ACPI_TYPE_PACKAGE; assert(!n1x_find_sensor("\\_TZ.TSOC", false, false));
	sensor_type = ACPI_TYPE_THERMAL; sensor_has_tmp = false;
	assert(!n1x_find_sensor("\\_TZ.TSOC", false, false));
	sensor_has_tmp = true; sensor_exists = false;
	assert(!n1x_find_sensor("\\_TZ.TSOC", false, false));
}
static void test_mmio_requires_valid_platform_id_and_window(void)
{
	struct n1x_priv priv = {0};
	reset_mocks(); platform_id=1; set_valid_limits();
	assert(init_mmio(&priv)==-ENODEV && mapped_length==0 && mmio_reads==0);
	reset_mocks(); mapping_fails=true; set_valid_limits();
	assert(init_mmio(&priv)==-ENOMEM);
	assert(mapped_physical==0x1c238000 && mapped_length==SPBM_SIZE);
	assert(mmio_reads==0 && mmio_writes==0);
}
static void test_every_limit_contract_is_checked(void)
{
	for (int i=0; i<ARRAY_SIZE(n1x_limit_slots); i++) {
		struct n1x_priv priv={0}; reset_mocks(); set_valid_limits();
		registers[n1x_limit_bounds[i]/4]=0;
		assert(init_mmio(&priv)==-ENODEV && mmio_writes==0);
	}
	for (int i=0; i<ARRAY_SIZE(n1x_limit_slots); i++) {
		struct n1x_priv priv={0}; reset_mocks(); set_valid_limits();
		registers[(n1x_limit_bounds[i]+4)/4]=250001;
		assert(init_mmio(&priv)==-ENODEV && mmio_writes==0);
	}
	for (int i=0; i<ARRAY_SIZE(n1x_limit_slots); i++) {
		struct n1x_priv priv={0}; reset_mocks(); set_valid_limits();
		registers[(0x120+n1x_limit_slots[i]*4)/4]=9999;
		assert(init_mmio(&priv)==-ENODEV && mmio_writes==0);
	}
	for (int i=0; i<ARRAY_SIZE(n1x_limit_slots); i++) {
		struct n1x_priv priv={0}; reset_mocks(); set_valid_limits();
		registers[(0x160+n1x_limit_slots[i]*4)/4]=9999;
		assert(init_mmio(&priv)==-ENODEV && mmio_writes==0);
	}
}
static void test_temperature_contract_and_valid_read_only_mapping(void)
{
	const u32 invalid[]={1999,4501};
	for (int i=0; i<ARRAY_SIZE(invalid); i++) {
		struct n1x_priv priv={0}; reset_mocks(); set_valid_limits();
		registers[0x818/4]=invalid[i];
		assert(init_mmio(&priv)==-ENODEV && mmio_writes==0);
	}
	struct n1x_priv priv={0}; long value=0;
	reset_mocks(); set_valid_limits();
	registers[0x31c/4]=120000;
	assert(init_mmio(&priv)==0);
	assert(mapped_physical==0x1c238000 && mapped_length==SPBM_SIZE);
	assert(n1x_mmio_visible(&priv,hwmon_power_cap,9)==0444);
	assert(n1x_mmio_visible(&priv,hwmon_power_min,12)==0444);
	assert(n1x_mmio_read(&priv,hwmon_power_input,8,&value)==0);
	assert(value==120000000L && mmio_writes==0);
}
int main(void)
{
	test_schema_accepts_nonzero_subindex();
	test_schema_requires_dsm_and_named_resource();
	test_schema_rejects_malformed_entries();
	test_thermal_sensor_type_and_power_units_are_gated();
	test_mmio_requires_valid_platform_id_and_window();
	test_every_limit_contract_is_checked();
	test_temperature_contract_and_valid_read_only_mapping();
	puts("PASS: production NVDA8810 ACPI schema and MMIO checks");
	return 0;
}

