/* SPDX-License-Identifier: GPL-2.0 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef uint32_t u32;
#include "n1x-p16-readonly.h"

int main(void)
{
	long value;

	assert(n1x_p16_probe_has_sensors(false, false, true));
	assert(n1x_p16_probe_has_sensors(true, false, false));
	assert(n1x_p16_probe_has_sensors(false, true, false));
	assert(!n1x_p16_probe_has_sensors(false, false, false));

	assert(n1x_p16_power_value(0, &value) && value == 0);
	assert(n1x_p16_power_value(1000000, &value) && value == 1000000000L);
	assert(!n1x_p16_power_value(1000001, &value));
	assert(!n1x_p16_power_value(UINT32_MAX, &value));
	puts("PASS: telemetry probe selection and power unit conversion");
	return 0;
}
