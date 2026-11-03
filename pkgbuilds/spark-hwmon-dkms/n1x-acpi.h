/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SPBM_N1X_ACPI_H
#define SPBM_N1X_ACPI_H

/* ACPI helpers shared with the host firmware-fixture tests. */
/*
 * RTX Spark NVDA8810 uses the flat MTEL resource-directory ABI, unlike
 * GB10's named sensor-offset ABI. Recognize that ABI before evaluating
 * optional thermal-zone accessors. Never reuse DGX offsets or map MMIO.
 */
static bool n1x_supported_schema(acpi_handle handle)
{
	static const char * const keys[] = { "CFL", "CPL", "CBL", "CCI", "CPI" };
	union acpi_object arg_elem = { .integer = { .type = ACPI_TYPE_INTEGER } };
	union acpi_object arg_pkg = { .package = {
		.type = ACPI_TYPE_PACKAGE, .count = 1, .elements = &arg_elem,
	} };
	union acpi_object *out;
	unsigned long seen = 0;
	int i, j;
	bool valid = false;

	if (!acpi_check_dsm(handle, &mtel_dsm_guid, 0, BIT(1) | BIT(2)))
		return false;
	if (spbm_dsm_find_resource(handle, "SPBM") < 0)
		return false;
	/* Resource-list positions and function-2 sub-indices are independent. */
	for (arg_elem.integer.value = 0; arg_elem.integer.value < 16;
	     arg_elem.integer.value++) {
		out = acpi_evaluate_dsm(handle, &mtel_dsm_guid, 0, 2, &arg_pkg);
		if (!out)
			continue;
		seen = 0;
		if (out->type != ACPI_TYPE_PACKAGE || out->package.count % 2)
			goto done;
		for (i = 0; i < out->package.count; i += 2) {
			union acpi_object *name = &out->package.elements[i];
			union acpi_object *offset = &out->package.elements[i + 1];

			if (name->type != ACPI_TYPE_STRING || offset->type != ACPI_TYPE_INTEGER ||
			    offset->integer.value > U32_MAX || offset->integer.value % 4)
				goto done;
			for (j = 0; j < ARRAY_SIZE(keys); j++) {
				if (strcmp(name->string.pointer, keys[j]))
					continue;
				if (seen & BIT(j))
					goto done;
				seen |= BIT(j);
			}
		}
		valid = seen == GENMASK(ARRAY_SIZE(keys) - 1, 0);
done:
		ACPI_FREE(out);
		if (valid)
			return true;
	}
	return false;
}

/* Discover only thermal-zone objects, never arbitrary similarly named devices. */
static acpi_handle n1x_find_sensor(const char *path, bool power, bool power_units_known)
{
	acpi_handle handle;
	acpi_object_type type;
	unsigned long long critical;

	if (power && !power_units_known)
		return NULL;
	if (ACPI_FAILURE(acpi_get_handle(NULL, (acpi_string)path, &handle)) ||
	    ACPI_FAILURE(acpi_get_type(handle, &type)) || type != ACPI_TYPE_THERMAL ||
	    !acpi_has_method(handle, "_TMP"))
		return NULL;
	/*
	 * In this MTEL ABI, PSYS/PSOC are mW telemetry disguised as thermal
	 * zones on validated firmware. The sentinel is an additional rejection
	 * check, NOT proof of units: real temperature zones can also use it.
	 */
	if (power && (ACPI_FAILURE(acpi_evaluate_integer(handle, "_CRT", NULL, &critical)) ||
		      critical != 0x7fffffff))
		return NULL;
	return handle;
}

#endif
